@echo off
REM ================================================================
REM  Movie Narrator - one-click setup and launcher for Windows
REM
REM  First run downloads and installs only what is missing:
REM    1. Python 3.12 if no usable Python 3.10+ is found
REM    2. a virtual environment in .venv
REM    3. the movie-narrator engine plus scene detection
REM    4. movie-narrator-web 1.0.4 with the engine-1.7.0 fix
REM    5. a static ffmpeg and ffprobe in tools\ffmpeg
REM    6. a CJK subtitle font in assets\fonts
REM    7. .env preconfigured for DeepSeek V4 Pro
REM  Then it opens a menu. The window never closes by itself:
REM  every path ends in the menu, a pause, or an error screen.
REM
REM  Usage: double-click run.bat, or from a terminal:
REM      run.bat                then type your DeepSeek API key
REM      run.bat sk-your-key    key passed directly, no prompt
REM ================================================================
chcp 65001 >nul
title Movie Narrator - Setup and Launcher
cd /d "%~dp0"
setlocal EnableExtensions

REM ---------------- settings ----------------
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
echo   Everything below is downloaded only once. Re-running later
echo   is fast and safe.
echo ================================================================
echo.

REM ---------------- 1. python ----------------
call :ensure_python
REM ---------------- 2. venv ----------------
call :make_venv
REM ---------------- 3. packages ----------------
call :install_packages
REM ---------------- 4. ffmpeg ----------------
call :get_ffmpeg
REM ---------------- 5. font ----------------
call :ensure_font
REM ---------------- 6. env ----------------
set "SCRIPT_KEY=%~1"
call :write_env

echo.
echo ================================================================
echo   Setup complete!
echo ================================================================
echo.

:menu
cls
echo ================================================================
echo   Movie Narrator
echo ================================================================
echo   [1] Create a recap video - command line wizard
echo   [2] Open the Web UI in your browser - port 8760
echo   [3] Check the setup - mn doctor
echo   [4] Exit
echo ================================================================
choice /c 1234 /n /m "Choose an option: "
if errorlevel 4 goto exit
if errorlevel 3 goto doctor
if errorlevel 2 goto webui
if errorlevel 1 goto create
goto menu

:create
cls
echo --- Create a recap video ---
echo.
set "MOVIE="
set /p "MOVIE=Movie name, required: "
if not defined MOVIE echo Movie name is required - going back to the menu.
if not defined MOVIE pause
if not defined MOVIE goto menu
set "DUR=60"
set /p "DUR=Target duration in seconds, Enter for 60: "
set "FMT=16:9"
set /p "FMT=Video format, 16:9 or 9:16, Enter for 16:9: "
set "STYLE="
set /p "STYLE=Narration style in any words, Enter for default: "
set "VID="
set /p "VID=Path to your source movie file, Enter to skip: "
set "ARGS=--movie "%MOVIE%" --duration %DUR% --format %FMT%"
if not "%STYLE%"=="" set "ARGS=%ARGS% --style "%STYLE%""
if not "%VID%"=="" set "ARGS=%ARGS% --video "%VID%""
echo.
echo Running: mn create %ARGS%
echo The finished video lands in the output folder.
echo.
call "%VENV%\Scripts\mn.exe" create %ARGS%
echo.
if errorlevel 1 echo [!] The pipeline reported a problem - read the messages above.
if not errorlevel 1 echo [OK] Done! Open the output folder and look for final.mp4
pause
goto menu

:webui
if not exist "%VENV%\Scripts\mn-web.exe" echo [!] Web UI is not installed - run setup again.
if not exist "%VENV%\Scripts\mn-web.exe" pause
if not exist "%VENV%\Scripts\mn-web.exe" goto menu
cls
echo [*] Starting the Web UI on http://localhost:8760 ...
start "Movie Narrator Web UI" "%VENV%\Scripts\mn-web.exe" --host 127.0.0.1 --port 8760
timeout /t 3 /nobreak >nul
start "" http://localhost:8760
echo.
echo [i] The Web UI runs in its own console window.
echo [i] Close that window to stop the Web UI.
echo [i] Generated videos appear in the output folder.
pause
goto menu

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

:exit
echo.
echo Goodbye!
timeout /t 5 >nul
exit /b 0

:fail
echo.
echo [X] Setup failed at step: %FAIL_STEP%
echo     Read the messages above, fix the problem, then run run.bat again.
pause
exit /b 1

REM ================ subroutines ================

:ensure_python
set "PYEXE="
for /f "delims=" %%I in ('where py 2^>nul') do if not defined PYEXE set "PYEXE=%%I"
if not defined PYEXE for /f "delims=" %%I in ('where python3 2^>nul') do if not defined PYEXE set "PYEXE=%%I"
if not defined PYEXE for /f "delims=" %%I in ('where python 2^>nul') do if not defined PYEXE set "PYEXE=%%I"
if defined PYEXE call :check_python_version
if defined PYV if %PYV% GEQ 310 goto python_ok
echo [*] No usable Python 3.10+ found - installing Python 3.12...
winget install -e --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements >nul 2>&1
set "PYEXE="
for /f "delims=" %%I in ('dir /b /s "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" 2^>nul') do if not defined PYEXE set "PYEXE=%%I"
if not defined PYEXE for /f "delims=" %%I in ('dir /b /s "%LOCALAPPDATA%\Programs\Python\Python3*\python.exe" 2^>nul') do if not defined PYEXE set "PYEXE=%%I"
if not defined PYEXE for /f "delims=" %%I in ('dir /b /s "%ProgramFiles%\Python3*\python.exe" 2^>nul') do if not defined PYEXE set "PYEXE=%%I"
if defined PYEXE goto python_found
echo [*] Downloading the official Python 3.12 installer...
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%PYTHON_URL%' -OutFile '%TEMP%\python-installer.exe' -UseBasicParsing"
if errorlevel 1 set "FAIL_STEP=downloading Python"
if errorlevel 1 goto fail
echo [*] Installing Python 3.12 silently for this user...
start /wait "" "%TEMP%\python-installer.exe" /quiet InstallAllUsers=0 PrependPath=1
if errorlevel 1 set "FAIL_STEP=installing Python"
if errorlevel 1 goto fail
set "PYEXE="
for /f "delims=" %%I in ('dir /b /s "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" 2^>nul') do if not defined PYEXE set "PYEXE=%%I"
if not defined PYEXE for /f "delims=" %%I in ('dir /b /s "%LOCALAPPDATA%\Programs\Python\Python3*\python.exe" 2^>nul') do if not defined PYEXE set "PYEXE=%%I"
if not defined PYEXE for /f "delims=" %%I in ('dir /b /s "%ProgramFiles%\Python3*\python.exe" 2^>nul') do if not defined PYEXE set "PYEXE=%%I"
if not defined PYEXE set "FAIL_STEP=locating Python after install"
if not defined PYEXE goto fail
:python_found
call :check_python_version
if not defined PYV set "FAIL_STEP=Python version check, need 3.10 or newer"
if not defined PYV goto fail
if %PYV% LSS 310 set "FAIL_STEP=Python too old, need 3.10 or newer"
if %PYV% LSS 310 goto fail
:python_ok
echo [OK] Python %PYMAJOR%.%PYMINOR% ready.
echo.
goto :eof

:check_python_version
set "PYMAJOR="
set "PYMINOR="
set "PYV="
for /f "tokens=1,2 delims=." %%A in ('"%PYEXE%" --version 2^>^&1 ^| findstr /r "^Python"') do (set "PYMAJOR=%%A" & set "PYMINOR=%%B")
if not defined PYMAJOR goto :eof
if not defined PYMINOR goto :eof
set "PYMAJOR=%PYMAJOR:~-1%"
set /a "PYV=%PYMAJOR%*100+%PYMINOR%" 2>nul
goto :eof

:make_venv
if exist "%VENV%\Scripts\python.exe" goto venv_ok
echo [*] Creating the virtual environment in .venv ...
"%PYEXE%" -m venv "%VENV%"
if errorlevel 1 set "FAIL_STEP=creating the virtual environment"
if errorlevel 1 goto fail
:venv_ok
set "PY=%CD%\%VENV%\Scripts\python.exe"
echo [OK] Virtual environment ready.
echo.
goto :eof

:install_packages
if exist "%VENV%\.mn-packages-ok" goto packages_ok
echo [*] Upgrading pip...
"%PY%" -m pip install -q -U pip
echo [*] Installing the movie-narrator engine with scene detection...
echo [*] This downloads a few hundred MB on the very first run.
if exist "pyproject.toml" "%PY%" -m pip install -e ".[media]"
if not exist "pyproject.toml" "%PY%" -m pip install "movie-narrator[media]"
if errorlevel 1 set "FAIL_STEP=installing movie-narrator"
if errorlevel 1 goto fail
echo [*] Installing the web UI package...
"%PY%" -m pip install "%WEBUI_PKG%"
if errorlevel 1 set "FAIL_STEP=installing movie-narrator-web"
if errorlevel 1 goto fail
echo [*] Applying the engine-1.7.0 compatibility patch to the web UI...
"%PY%" -c "import re; from pathlib import Path; p = Path(r'%VENV%/Lib/site-packages/movie_narrator_web/form.py'); s = p.read_text(encoding='utf-8'); s2 = re.sub(r'(?m)^(\s*)format=data\.format', r'\1video_format=data.format', s); p.write_text(s2, encoding='utf-8'); raise SystemExit(0 if 'video_format=data.format' in s2 else 1)"
if errorlevel 1 set "FAIL_STEP=patching movie-narrator-web form.py"
if errorlevel 1 goto fail
echo [OK] Web UI patch applied.
type nul > "%VENV%\.mn-packages-ok"
:packages_ok
echo [OK] Python packages ready.
echo.
goto :eof

:get_ffmpeg
if exist "tools\ffmpeg\bin\ffprobe.exe" goto ffmpeg_ok
echo [*] Downloading a static ffmpeg + ffprobe build...
if not exist "tools" mkdir "tools"
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%FFMPEG_URL%' -OutFile 'tools\ffmpeg.zip' -UseBasicParsing"
if errorlevel 1 echo [!] Primary download failed - trying the mirror...
if errorlevel 1 powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%FFMPEG_URL2%' -OutFile 'tools\ffmpeg.zip' -UseBasicParsing"
if errorlevel 1 set "FAIL_STEP=downloading ffmpeg"
if errorlevel 1 goto fail
echo [*] Extracting ffmpeg...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath 'tools\ffmpeg.zip' -DestinationPath 'tools\ffmpeg-raw' -Force"
if errorlevel 1 set "FAIL_STEP=extracting ffmpeg"
if errorlevel 1 goto fail
if not exist "tools\ffmpeg" mkdir "tools\ffmpeg"
for /f "delims=" %%D in ('dir /b /ad "tools\ffmpeg-raw" 2^>nul') do if exist "tools\ffmpeg-raw\%%D\bin\ffmpeg.exe" move /y "tools\ffmpeg-raw\%%D\bin" "tools\ffmpeg\bin" >nul
if not exist "tools\ffmpeg\bin\ffmpeg.exe" set "FAIL_STEP=extracting ffmpeg, bin folder not found"
if not exist "tools\ffmpeg\bin\ffmpeg.exe" goto fail
del /q "tools\ffmpeg.zip" >nul 2>&1
rmdir /s /q "tools\ffmpeg-raw" >nul 2>&1
:ffmpeg_ok
set "PATH=%CD%\tools\ffmpeg\bin;%PATH%"
set "MN_FFMPEG_BIN=%CD%\tools\ffmpeg\bin\ffmpeg.exe"
echo [OK] ffmpeg ready.
echo.
goto :eof

:ensure_font
if exist "assets\fonts\NotoSansSC-Regular.otf" goto font_ok
echo [*] Installing a CJK font for subtitles...
"%PY%" -m pip install -q pymupdf
"%PY%" -c "import pymupdf, os; os.makedirs('assets/fonts', exist_ok=True); open('assets/fonts/NotoSansSC-Regular.otf','wb').write(pymupdf.Font('china-s').buffer)"
if errorlevel 1 set "FAIL_STEP=installing the CJK font"
if errorlevel 1 goto fail
:font_ok
echo [OK] Subtitle font ready.
echo.
goto :eof

:write_env
if exist ".env" goto env_ok
set "DS_KEY="
if not "%SCRIPT_KEY%"=="" set "DS_KEY=%SCRIPT_KEY%"
if not defined DS_KEY set /p "DS_KEY=Enter your DeepSeek API key, it starts with sk-: "
if not defined DS_KEY echo [i] No key entered - you can edit .env later.
if not defined DS_KEY set "DS_KEY=PUT-YOUR-DEEPSEEK-API-KEY-HERE"
> ".env" echo # Movie Narrator - project configuration
>> ".env" echo # LLM: DeepSeek V4 Pro, OpenAI-compatible endpoint.
>> ".env" echo # Create a key at https://platform.deepseek.com
>> ".env" echo MN_LLM_BASE_URL=%DS_BASE_URL%
>> ".env" echo MN_LLM_API_KEY=%DS_KEY%
>> ".env" echo MN_LLM_MODEL=%DS_MODEL%
>> ".env" echo MN_DEFAULT_VOICE=%DS_VOICE%
>> ".env" echo # TTS provider edge is free and needs no key, personal use only.
>> ".env" echo # For commercial use set MN_TTS_PROVIDER=openai or mimo.
echo [OK] .env written for model %DS_MODEL%
goto env_done
:env_ok
echo [i] .env already exists - keeping your current settings.
:env_done
echo.
goto :eof
