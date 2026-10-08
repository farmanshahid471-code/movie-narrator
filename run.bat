@echo off
REM ================================================================
REM  Movie Narrator - one-click setup and launcher (Windows)
REM
REM  What it does on first run (downloads only what is missing,
REM  so it is safe to run again at any time):
REM    1. Installs Python 3.12 if no usable Python 3.10+ is found
REM    2. Creates a virtual environment (.venv)
REM    3. Installs the movie-narrator engine (+ scene detection)
REM    4. Installs movie-narrator-web 1.0.4 (FastAPI + React UI,
REM       includes the prebuilt web app) and applies the upstream
REM       engine-1.7.0 compatibility patch (format -> video_format)
REM    5. Downloads a static ffmpeg + ffprobe into tools\ffmpeg
REM    6. Ensures a CJK font exists for subtitles (assets\fonts)
REM    7. Writes .env with your DeepSeek V4 Pro settings
REM
REM  Usage:
REM    - Double-click run.bat, or run it from a terminal:
REM        run.bat
REM    - Or pass your DeepSeek API key directly:
REM        run.bat sk-your-key-here
REM
REM  The window stays open on a menu - it never just closes.
REM ================================================================
chcp 65001 >nul
title Movie Narrator - Setup and Launcher
cd /d "%~dp0"
setlocal EnableExtensions

REM ---------------- User-editable settings ----------------
set "DS_BASE_URL=https://api.deepseek.com/v1"
set "DS_MODEL=deepseek-v4-pro"
set "DS_VOICE=zh-CN-YunxiNeural"
set "PYTHON_URL=https://www.python.org/ftp/python/3.12.15/python-3.12.15-amd64.exe"
set "FFMPEG_URL=https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
set "FFMPEG_URL2=https://www.johnvansickle.com/ffmpeg/releases/ffmpeg-release-win64-static.zip"
set "WEBUI_PKG=movie-narrator-web==1.0.4"
set "VENV=.venv"

echo ================================================================
echo   Movie Narrator - first-run setup
echo ================================================================
echo   This installs everything the tool needs. Only missing pieces
echo   are downloaded, so re-running is always safe.
echo ================================================================
echo.

REM ---------------- 1. Find or install Python 3.10+ ----------------
set "PYEXE="
for /f %%I in ('where py 2^>nul') do set "PYEXE=%%I"
if not defined PYEXE for /f %%I in ('where python3 2^>nul') do set "PYEXE=%%I"
if not defined PYEXE for /f %%I in ('where python 2^>nul') do set "PYEXE=%%I"

call :check_python_version
if not defined PYMAJOR goto install_python
if %PYMAJOR% GTR 3 goto python_ok
if %PYMAJOR%==3 if %PYMINOR% GEQ 10 goto python_ok
goto install_python

:python_ok
echo [OK] Python %PYMAJOR%.%PYMINOR% ready.
echo.

REM ---------------- 2. Virtual environment ----------------
if not exist "%VENV%\Scripts\python.exe" (
  echo [*] Creating virtual environment (.venv)...
  "%PYEXE%" -m venv "%VENV%"
  if errorlevel 1 set "FAIL_STEP=creating the virtual environment"
  if errorlevel 1 goto fail
)
set "PY=%VENV%\Scripts\python.exe"
echo [OK] Virtual environment ready.
echo.

REM ---------------- 3. Python packages ----------------
if exist "%VENV%\.mn-packages-ok" goto packages_ok
echo [*] Upgrading pip...
"%PY%" -m pip install -q -U pip
echo [*] Installing movie-narrator engine (+ scene detection)...
REM  Editable install on purpose: the renderer looks for the subtitle
REM  font at <repo>\assets\fonts, which only resolves from the source tree.
if exist "pyproject.toml" "%PY%" -m pip install -e ".[media]"
if not exist "pyproject.toml" "%PY%" -m pip install "movie-narrator[media]"
if errorlevel 1 set "FAIL_STEP=installing movie-narrator"
if errorlevel 1 goto fail
echo [*] Installing movie-narrator-web UI (includes the built web app)...
"%PY%" -m pip install "%WEBUI_PKG%"
if errorlevel 1 set "FAIL_STEP=installing movie-narrator-web"
if errorlevel 1 goto fail
echo [*] Applying engine-1.7.0 compatibility patch to the web UI...
"%PY%" -c "import re; from pathlib import Path; p = Path(r'%VENV%/Lib/site-packages/movie_narrator_web/form.py'); s = p.read_text(encoding='utf-8'); s2 = re.sub(r'(?m)^(\s*)format=data\.format', r'\1video_format=data.format', s); p.write_text(s2, encoding='utf-8'); raise SystemExit(0 if 'video_format=data.format' in s2 else 1)"
if errorlevel 1 set "FAIL_STEP=patching movie-narrator-web (form.py)"
if errorlevel 1 goto fail
echo [OK] Web UI patch applied.
type nul > "%VENV%\.mn-packages-ok"
:packages_ok
echo [OK] Python packages ready.
echo.

REM ---------------- 4. ffmpeg + ffprobe ----------------
if exist "tools\ffmpeg\bin\ffprobe.exe" goto ffmpeg_ok
echo [*] Downloading ffmpeg + ffprobe (static build)...
if not exist "tools" mkdir "tools"
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%FFMPEG_URL%' -OutFile 'tools\ffmpeg.zip' -UseBasicParsing"
if errorlevel 1 echo [!] Primary source failed - trying mirror...
if errorlevel 1 powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%FFMPEG_URL2%' -OutFile 'tools\ffmpeg.zip' -UseBasicParsing"
if errorlevel 1 set "FAIL_STEP=downloading ffmpeg"
if errorlevel 1 goto fail
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath 'tools\ffmpeg.zip' -DestinationPath 'tools\ffmpeg-raw' -Force"
if errorlevel 1 set "FAIL_STEP=extracting ffmpeg"
if errorlevel 1 goto fail
if not exist "tools\ffmpeg" mkdir "tools\ffmpeg"
for /d %%D in ("tools\ffmpeg-raw\*") do if exist "%%D\bin\ffmpeg.exe" move /y "%%D\bin" "tools\ffmpeg\bin" >nul
if not exist "tools\ffmpeg\bin\ffmpeg.exe" set "FAIL_STEP=extracting ffmpeg (bin folder not found)"
if not exist "tools\ffmpeg\bin\ffmpeg.exe" goto fail
del /q "tools\ffmpeg.zip" >nul 2>&1
rmdir /s /q "tools\ffmpeg-raw" >nul 2>&1
:ffmpeg_ok
set "PATH=%CD%\tools\ffmpeg\bin;%PATH%"
set "MN_FFMPEG_BIN=%CD%\tools\ffmpeg\bin\ffmpeg.exe"
echo [OK] ffmpeg ready.
echo.

REM ---------------- 5. CJK font for subtitles ----------------
if exist "assets\fonts\NotoSansSC-Regular.otf" goto font_ok
echo [*] Installing a CJK font for subtitles...
"%PY%" -m pip install -q pymupdf
"%PY%" -c "import pymupdf, os; os.makedirs('assets/fonts', exist_ok=True); open('assets/fonts/NotoSansSC-Regular.otf', 'wb').write(pymupdf.Font('china-s').buffer)"
if errorlevel 1 set "FAIL_STEP=installing the CJK font"
if errorlevel 1 goto fail
:font_ok
echo [OK] Font ready.
echo.

REM ---------------- 6. .env (DeepSeek V4 Pro) ----------------
if exist ".env" goto env_ok
set "DS_KEY="
if not "%~1"=="" set "DS_KEY=%~1"
if not defined DS_KEY set /p "DS_KEY=Enter your DeepSeek API key (starts with sk-): "
if not defined DS_KEY echo [i] No key entered - edit .env and add your key later.
if not defined DS_KEY set "DS_KEY=PUT-YOUR-DEEPSEEK-API-KEY-HERE"
> ".env" echo # Movie Narrator - project configuration
>> ".env" echo # LLM: DeepSeek V4 Pro via the OpenAI-compatible endpoint
>> ".env" echo # Create a key at https://platform.deepseek.com
>> ".env" echo MN_LLM_BASE_URL=%DS_BASE_URL%
>> ".env" echo MN_LLM_API_KEY=%DS_KEY%
>> ".env" echo MN_LLM_MODEL=%DS_MODEL%
>> ".env" echo MN_DEFAULT_VOICE=%DS_VOICE%
>> ".env" echo # TTS provider "edge" is free and needs no key (personal use only).
>> ".env" echo # For commercial use set MN_TTS_PROVIDER=openai or mimo.
echo [OK] .env written - model: %DS_MODEL%
goto env_done
:env_ok
echo [i] .env already exists - keeping your current settings.
:env_done
echo.

echo ================================================================
echo   Setup complete!
echo ================================================================
echo.
goto menu

REM ---------------- Menu ----------------
:menu
cls
echo ================================================================
echo   Movie Narrator
echo ================================================================
echo   [1] Create a recap video (command line wizard)
echo   [2] Open the Web UI (browser, http://localhost:8760)
echo   [3] Check setup (mn doctor)
echo   [4] Exit
echo ================================================================
choice /c 1234 /n /m "Choose: "
if errorlevel 4 goto exit
if errorlevel 3 goto doctor
if errorlevel 2 goto webui
if errorlevel 1 goto create
goto menu

REM ---------------- [1] Create a video ----------------
:create
cls
echo --- Create a recap video ---
echo.
set "MOVIE="
set /p "MOVIE=Movie name (required): "
if not defined MOVIE echo Movie name is required - going back to the menu.
if not defined MOVIE pause
if not defined MOVIE goto menu
set "DUR=60"
set /p "DUR=Target duration in seconds [60]: "
set "FMT=16:9"
set /p "FMT=Video format - 16:9 or 9:16 [16:9]: "
set "STYLE="
set /p "STYLE=Narration style, any words you like (empty = default): "
set "VID="
set /p "VID=Path to the source movie file, e.g. C:\movies\film.mp4 (empty = no footage): "
set "ARGS=--movie "%MOVIE%" --duration %DUR% --format %FMT%"
if not "%STYLE%"=="" set "ARGS=%ARGS% --style "%STYLE%""
if not "%VID%"=="" set "ARGS=%ARGS% --video "%VID%""
echo.
echo Running: mn create %ARGS%
echo (The finished video lands in the "output" folder.)
echo.
call "%VENV%\Scripts\mn.exe" create %ARGS%
echo.
if errorlevel 1 echo [!] The pipeline reported a problem - read the messages above.
if not errorlevel 1 echo [OK] Done! Look for final.mp4 in the "output" folder.
pause
goto menu

REM ---------------- [2] Web UI ----------------
:webui
if not exist "%VENV%\Scripts\mn-web.exe" echo [!] Web UI is not installed - run the setup again.
if not exist "%VENV%\Scripts\mn-web.exe" pause
if not exist "%VENV%\Scripts\mn-web.exe" goto menu
cls
echo [*] Starting the Web UI on http://localhost:8760 ...
start "Movie Narrator Web UI" "%VENV%\Scripts\mn-web.exe" --host 127.0.0.1 --port 8760
timeout /t 3 /nobreak >nul
start "" http://localhost:8760
echo.
echo [i] The Web UI runs in its own window - close that window to stop it.
echo [i] Generated videos appear under the "output" folder.
pause
goto menu

REM ---------------- [3] Setup check ----------------
:doctor
cls
echo --- Setup check ---
echo.
call "%VENV%\Scripts\mn.exe" version
echo.
call "%VENV%\Scripts\mn.exe" doctor
echo.
"%PY%" -c "import movie_narrator; print('engine package: OK')"
"%PY%" -c "import movie_narrator_web; print('web UI package: OK')"
echo.
pause
goto menu

REM ---------------- Error exit ----------------
:fail
echo.
echo [X] Setup failed: %FAIL_STEP%
echo     Fix the problem above, then run run.bat again.
pause
exit /b 1

REM ---------------- Exit ----------------
:exit
echo.
echo Goodbye!
pause
exit /b 0

REM ---------------- Subroutines ----------------
:install_python
echo [*] No usable Python 3.10+ found - installing Python 3.12...
winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements >nul 2>&1
set "PYEXE="
for /f %%I in ('dir /b /s "%LOCALAPPDATA%\Programs\Python\Python3*\python.exe" 2^>nul') do set "PYEXE=%%I"
if not defined PYEXE where python >nul 2>&1 && set "PYEXE=python"
if not defined PYEXE (
  echo [*] Downloading the official Python installer...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%PYTHON_URL%' -OutFile '%TEMP%\python-installer.exe' -UseBasicParsing"
  if errorlevel 1 set "FAIL_STEP=downloading Python"
  if errorlevel 1 goto fail
  echo [*] Installing Python 3.12 (silent, per-user)...
  start /wait "" "%TEMP%\python-installer.exe" /quiet InstallAllUsers=0 PrependPath=1
  if errorlevel 1 set "FAIL_STEP=installing Python"
  if errorlevel 1 goto fail
  set "PYEXE="
  for /f %%I in ('dir /b /s "%LOCALAPPDATA%\Programs\Python\Python3*\python.exe" 2^>nul') do set "PYEXE=%%I"
  if not defined PYEXE for /f %%I in ('dir /b /s "%ProgramFiles%\Python3*\python.exe" 2^>nul') do set "PYEXE=%%I"
)
if not defined PYEXE set "FAIL_STEP=locating Python after install"
if not defined PYEXE goto fail
call :check_python_version
if not defined PYMAJOR set "FAIL_STEP=Python version check"
if not defined PYMAJOR goto fail
if %PYMAJOR% LSS 3 set "FAIL_STEP=Python 3.10+ required"
if %PYMAJOR% LSS 3 goto fail
if %PYMAJOR%==3 if %PYMINOR% LSS 10 set "FAIL_STEP=Python 3.10+ required (found %PYMAJOR%.%PYMINOR%)"
if %PYMAJOR%==3 if %PYMINOR% LSS 10 goto fail
goto python_ok

:check_python_version
set "PYMAJOR="
set "PYMINOR="
for /f "tokens=2,3 delims=. " %%A in ('%PYEXE% --version 2^>^&1') do (set "PYMAJOR=%%A" & set "PYMINOR=%%B")
goto :eof
