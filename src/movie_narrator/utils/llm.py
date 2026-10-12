# SPDX-FileCopyrightText: 2026 zcbacxc
# SPDX-License-Identifier: AGPL-3.0-or-later

"""LLM client factory backed by the provider registry.

The built-in ``"openai"`` provider is registered at import time.
External plugins can register additional LLM providers via
:func:`register_llm`.

``get_llm_client()`` remains a zero-argument callable that returns a
context manager yielding :class:`LLMClient`. This preserves backward
compatibility with all existing call sites and test patches.

Since v0.9.1 the yielded client context runs under the shared ``"llm"``
circuit breaker: when the circuit is open, entering ``with
get_llm_client() as llm:`` raises :class:`CircuitOpenError` (retryable)
without creating a client or touching the network.
"""

import json
from dataclasses import dataclass
from contextlib import contextmanager
from typing import Iterator

import httpx
from openai import APIStatusError, OpenAI

from ..config import get_settings
from ..providers import llm_registry, register_llm
from ..reliability import CIRCUIT_REGISTRY, RetryPolicy, with_retry
from ..tracing import wrap_provider_call  # v1.4.0 — opt-in provider spans
from ..workflow.errors import is_network_error


@dataclass
class LLMClient:
    """LLM client wrapper with model reference."""

    client: OpenAI
    model: str


def _llm_should_retry(exc: BaseException) -> bool:
    """Decide whether an LLM chat-completion failure warrants a retry.

    Retries transient failures only: exceptions flagged ``retryable``,
    network/timeout errors, OpenAI rate-limit errors (429) and server
    errors (5xx). Configuration and logic errors fail fast.
    """
    if getattr(exc, "retryable", False) or is_network_error(exc):
        return True
    return isinstance(exc, APIStatusError) and getattr(exc, "status_code", 0) >= 500


# v1.2: LLM chat-completion calls share one retry policy. The OpenAI SDK's
# internal retries are disabled (``max_retries=0``) so this policy is the
# single source of truth for backoff. The "llm" circuit breaker in
# ``get_llm_client`` remains the OUTER guard; this retry loop is INNER
# (per ``create`` call).
LLM_RETRY_POLICY = RetryPolicy(
    max_attempts=3,
    base_delay=1.0,
    max_delay=8.0,
    multiplier=2.0,
    jitter=0.1,
    should_retry=_llm_should_retry,
)


def _record_llm_usage(create):
    """v1.5.1: count every completion attempt in the usage ledger.

    Wrapped *inside* the retry policy so each retry attempt is recorded
    (including the failure outcome). One record per attempt: attempts,
    errors, prompt/response chars. Call-kind attribution is not
    available at this shared boundary, so records land under
    ``kind="other"``; ``record_llm`` supports the finer kinds
    (research / script_beats / script_expand / judge) for callers that
    know them.
    """
    from .cost_ledger import get_usage_ledger

    def _inner(*args, **kwargs):
        messages = kwargs.get("messages")
        if messages is None and args:
            first = args[0]
            messages = first if isinstance(first, list) else None
        prompt_chars = sum(
            len(str(m.get("content") or ""))
            for m in (messages or [])
            if isinstance(m, dict)
        )
        ledger = get_usage_ledger()
        try:
            response = create(*args, **kwargs)
        except Exception:
            ledger.record_llm(attempts=1, prompt_chars=prompt_chars, error=True)
            raise
        resp_chars = 0
        choices = getattr(response, "choices", None)
        if choices:
            resp_chars = len(getattr(choices[0].message, "content", None) or "")
        ledger.record_llm(attempts=1, prompt_chars=prompt_chars, resp_chars=resp_chars)
        return response

    return _inner


def _wrap_llm_retry(client: OpenAI) -> OpenAI:
    """Wrap the chat-completion ``create`` method in the shared retry policy.

    Only ``client.chat.completions.create`` is wrapped — research / script /
    judge all go through it. Other OpenAI client surfaces are untouched.
    Does not introduce any idempotency/short-circuit cache: every call is
    forwarded to the model (LLM outputs are non-deterministic, so caching
    concrete responses would risk stale reuse).

    v1.4.0: each ``create`` call also runs inside one provider span
    (retry attempts included). No-op unless ``MN_TRACING`` is enabled.

    v1.5.1: each attempt is also counted in the usage ledger (see
    ``utils/cost_ledger.py``) — always-on, no I/O.
    """
    client.chat.completions.create = wrap_provider_call(
        with_retry(LLM_RETRY_POLICY)(_record_llm_usage(client.chat.completions.create)),
        "openai",
        "llm",
        model=get_settings().llm_model,
    )
    return client


def _wrap_llm_extra_body(client: OpenAI, extra_body_json: str) -> OpenAI:
    """Merge an optional JSON object into every chat-completions request.

    ``extra_body_json`` comes from ``settings.llm_extra_body`` (the
    ``MN_LLM_EXTRA_BODY`` env var) and is injected through the OpenAI
    SDK's ``extra_body`` parameter, e.g. ``{"thinking": {"type":
    "disabled"}}`` for DeepSeek V4 models whose reasoning mode is on by
    default. When the setting is empty — the default — the client is
    returned untouched and no request gains any new field, so existing
    deployments behave exactly as before. Values a caller passes via its
    own ``extra_body`` keyword win over the merged defaults.
    """
    extra = json.loads(extra_body_json) if extra_body_json.strip() else {}
    if not extra:
        return client
    if not isinstance(extra, dict):
        raise ValueError("MN_LLM_EXTRA_BODY must be a JSON object")
    original_create = client.chat.completions.create

    def _create_with_extra_body(*args, **kwargs):
        kwargs["extra_body"] = {**extra, **(kwargs.get("extra_body") or {})}
        return original_create(*args, **kwargs)

    client.chat.completions.create = _create_with_extra_body
    return client


# ── Built-in "openai" provider ───────────────────────────


@register_llm("openai")
def _make_openai_llm():
    """Factory for the OpenAI-compatible LLM provider.

    Returns:
        A context manager that yields an :class:`LLMClient`
        backed by a managed ``httpx.Client`` (closed on exit).
    """

    @contextmanager
    def _cm():
        settings = get_settings()
        http_client = httpx.Client(timeout=settings.llm_timeout)
        try:
            client = OpenAI(
                base_url=settings.llm_base_url,
                api_key=settings.llm_api_key,
                http_client=http_client,
                max_retries=0,  # the shared RetryPolicy is the single retry source
            )
            client = _wrap_llm_retry(client)
            client = _wrap_llm_extra_body(client, settings.llm_extra_body)
            yield LLMClient(client=client, model=settings.llm_model)
        finally:
            http_client.close()

    return _cm()


# ── Public factory function ──────────────────────────────


@contextmanager
def get_llm_client() -> Iterator[LLMClient]:
    """Yield an LLMClient via the llm_registry.

    Dispatches to the provider configured by ``settings.llm_provider``
    (default: ``"openai"``). The returned object is a context manager
    that must be used in a ``with`` statement.

    Since v0.9.1 the client context runs under the shared ``"llm"``
    circuit breaker: when the circuit is open, entering the ``with``
    block raises :class:`CircuitOpenError` (retryable) before the
    provider factory is invoked, so no client is created and no network
    request is attempted. Exceptions raised inside the ``with`` body are
    recorded as breaker failures before propagating unchanged.

    This function's module path (``movie_narrator.utils.llm``) and
    zero-argument signature are preserved for backward compatibility
    with existing call sites and test patches.
    """
    settings = get_settings()
    breaker = CIRCUIT_REGISTRY["llm"]
    with breaker.guard():
        cm = llm_registry.create(settings.llm_provider)
        with cm as llm:
            yield llm
