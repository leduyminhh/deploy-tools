@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul

REM ========================================
REM ========== LOAD CONFIG FROM .ENV =======
REM ========================================
for /f "tokens=1,* delims==" %%i in (.env) do (
    set "%%i=%%j"
)

REM ========================================
REM ========== ROUTER ======================
REM ========================================
if /i "%1"=="check"   goto :CHECK
if /i "%1"=="install" goto :INSTALL
if /i "%1"=="push"    goto :PUSH

if /i "%1"=="-h"  (
    goto :HELP
) else if /i "%1"=="help" (
    goto :HELP
) else if /i "%1"=="-help" (
    goto :HELP
)

echo =============================================
echo Usage:
echo   deploy.bat check      ^> Kiểm tra module + JAR
echo   deploy.bat install    ^> Maven install + copy JAR vào history
echo   deploy.bat push       ^> Upload JAR trong history lên server
echo =============================================
exit /b

REM ========================================
REM ========== LOAD IGNORE LIST ============
REM ========================================
:LOAD_IGNORE_LIST
set "IGNORE_LIST="
if exist ".deployignore" (
    for /f "usebackq tokens=* delims=" %%i in (".deployignore") do (
        set "line=%%i"
        if not "!line!"=="" if "!line:~0,1!" NEQ "#" (
            if "!line:~0,3!"=="﻿" set "line=!line:~3!"
            for /f "tokens=* delims= " %%j in ("!line!") do (
                set "line=%%j"
                set "IGNORE_LIST=!IGNORE_LIST!!line!;"
            )
        )
    )
)
exit /b

REM ========================================
REM ========== BUILD MODULE LIST ===========
REM ========================================
:LOAD_MODULES
set "MODULES="

REM Đọc danh sách module từ pom.xml
set "SKIPPED_MODULES="

for /f "tokens=3 delims=<>" %%m in ('findstr "<module>" "%PROJECT_ROOT%\pom.xml"') do (
    set "curModule=%%m"
    set "skip=0"

    REM Check trong ignore list
    for %%i in (!IGNORE_LIST!) do (
        if /i "%%i"=="!curModule!" (
            set "skip=1"
        )
    )

    REM Nếu skip=0 thì mới add vào MODULES
    if "!skip!"=="0" (
        set "MODULES=!MODULES! %%m"
    ) else (
        REM Append vào danh sách bị bỏ qua (không dùng if defined)
        if not "!SKIPPED_MODULES!"=="" (
            set "SKIPPED_MODULES=!SKIPPED_MODULES!, %%m"
        ) else (
            set "SKIPPED_MODULES=%%m"
        )
    )
)

if not "!SKIPPED_MODULES!"=="" (
    echo [INFO] Bỏ qua modules: !SKIPPED_MODULES!
) else (
    echo [INFO] Không có module nào bị bỏ qua
)
echo.
exit /b

REM ========================================
REM ========== CHECK MODULES ===============
REM ========================================
:CHECK
call :LOAD_IGNORE_LIST
call :LOAD_MODULES


echo =============================================
echo [CHECK] Kiểm tra modules trong pom cha
echo =============================================

pushd "%PROJECT_ROOT%"
for %%m in (!MODULES!) do (
    echo [CHECKING] Module: %%m
    if exist "%%m\pom.xml" (
        echo    [✔] pom.xml tồn tại trong %%m
        dir /b "%%m\target\*.jar" >nul 2>nul
        if errorlevel 1 (
            echo    [⚠] Không tìm thấy JAR trong %%m\target → CHƯA BUILD?
        ) else (
            for %%f in ("%%m\target\*.jar") do (
                echo    [✔] JAR: %%~nxf
            )
        )
    ) else (
        echo    [✘] Thiếu pom.xml trong %%m
    )
    echo.
)
echo ---------------------------------------------
echo [CHECKED] Hoàn tất kiểm tra module.
popd
exit /b

REM ========================================
REM ========== INSTALL MODULES =============
REM ========================================

:INSTALL
echo =============================================
echo [INSTALL] Bắt đầu build modules...
echo =============================================

REM --- Load ignore list và module list ---
call :LOAD_IGNORE_LIST
call :LOAD_MODULES

REM --- Khởi tạo biến ---
set "WITH_PARENT=false"
set "TARGET_MODULE="

REM --- Parse args: nhận module + --with-parent ở bất kỳ vị trí %2..%4 ---
for %%A in ("%~2" "%~3" "%~4") do (
    if not "%%~A"=="" (
        if /i "%%~A"=="--with-parent" (
            set "WITH_PARENT=true"
        ) else (
            if "%TARGET_MODULE%"=="" set "TARGET_MODULE=%%~A"
        )
    )
)

REM --- Tính danh sách module thực sự deploy ---
set "DEPLOY_MODULES="
for %%m in (!MODULES!) do (
    set "skipTarget="
    set "skipIgnore="

    if not "%TARGET_MODULE%"=="" if /i "%%m" NEQ "%TARGET_MODULE%" set "skipTarget=1"
    for %%i in (!IGNORE_LIST!) do (
        if /i "%%m"=="%%i" set "skipIgnore=1"
    )

    if "!skipTarget!"=="" if "!skipIgnore!"=="" (
        if not "!DEPLOY_MODULES!"=="" (
            set "DEPLOY_MODULES=!DEPLOY_MODULES!,%%m"
        ) else (
            set "DEPLOY_MODULES=%%m"
        )
    )
)

echo [INFO] Các module sẽ deploy: !DEPLOY_MODULES!
echo.

pushd "%PROJECT_ROOT%"

REM --- Build parent nếu được yêu cầu ---
if /i "%WITH_PARENT%"=="true" (
    echo [BUILD] Parent POM
    call mvn clean install -N -DskipTests
    echo ✅ [OK] Parent đã install vào local repo
)

REM --- Build từng module ---
set "SUCCESS_MODULES="
set "FAILED_MODULES="

for %%m in (!DEPLOY_MODULES!) do (
    echo ---------------------------------------------
    echo [BUILD] Module: %%m

    pushd "%%m"
    call mvn clean install -DskipTests
    if errorlevel 1 (
        if not "!FAILED_MODULES!"=="" (
            set "FAILED_MODULES=!FAILED_MODULES!, %%m"
        ) else (
            set "FAILED_MODULES=%%m"
        )
    ) else (
        if not "!SUCCESS_MODULES!"=="" (
            set "SUCCESS_MODULES=!SUCCESS_MODULES!, %%m"
        ) else (
            set "SUCCESS_MODULES=%%m"
        )
    )
    popd
)

REM --- Xóa thư mục cũ đảm bảo lưu < MAX_HISTORY
call :CLEAN_OLD_HISTORY

REM --- Tạo folder timestamp mới ---
call :CREATE_TIMESTAMP_FOLDER

REM --- Copy tất cả JAR vào folder timestamp ---
call :COPY_JARS

popd

echo.
echo =============================================
if not "!SUCCESS_MODULES!"=="" echo ✅ [SUCCESS] Modules build thành công: !SUCCESS_MODULES!
if not "!FAILED_MODULES!"=="" echo ❌ [FAILED ] Modules build thất bại: !FAILED_MODULES!

echo [INFO] JARs đã copy sang folder: !HISTORY_TIMESTAMP_FOLDER!
echo =============================================
exit /b

:CLEAN_OLD_HISTORY
setlocal EnableDelayedExpansion

REM --- Lấy danh sách folder theo thời gian mới nhất
set "FOLDER_LIST="
for /f "delims=" %%F in ('dir /b /ad /o-d "%HISTORY_DIR%"') do (
    if "!FOLDER_LIST!"=="" (
        set "FOLDER_LIST=%%F"
    ) else (
        set "FOLDER_LIST=!FOLDER_LIST!,%%F"
    )
)

REM --- Duyệt để xóa nếu vượt MAX_HISTORY ---
set /a COUNT=0
for %%F in (!FOLDER_LIST!) do (
    set /a COUNT+=1
    if !COUNT! GTR %MAX_HISTORY% (
        echo [INFO] Xóa folder cũ: %%F
        rmdir /s /q "%HISTORY_DIR%\%%F" 2>nul || echo [WARN] Không xóa được folder: %%F
    )
)

endlocal
exit /b


:CREATE_TIMESTAMP_FOLDER
REM --- Tạo folder timestamp trong HISTORY_DIR ---

for /f "tokens=1-3 delims=:." %%h in ("%TIME%") do (
    set "HH=%%h"
    set "MIN=%%i"
    set "SEC=%%j"
)

for /f "tokens=2-4 delims=/.- " %%d in ("%DATE%") do (
    set "DD=%%d"
    set "MON=%%e"
    set "YYYY=%%f"
)

REM Lấy ngày trong tuần (Mon/Tue/...) từ %DATE% nếu muốn
set "DAY=%DATE:~0,3%"

REM Đặt format folder: day_hhmm_ddMMyyyy
set "HISTORY_TIMESTAMP_FOLDER=%HISTORY_DIR%\!MON!!DD!!YYYY!_!HH!!MIN!!SEC!_%DAY%"
if not exist "!HISTORY_TIMESTAMP_FOLDER!" mkdir "!HISTORY_TIMESTAMP_FOLDER!"

:COPY_JARS
REM --- Copy tất cả JAR vào folder timestamp ---
setlocal EnableDelayedExpansion
for %%m in (!DEPLOY_MODULES!) do (
    set "MODULE_PATH=!PROJECT_ROOT!\%%m"
    if exist "!MODULE_PATH!\target" (
        for %%f in ("!MODULE_PATH!\target\*.jar") do (
            copy /Y "%%f" "!HISTORY_TIMESTAMP_FOLDER!\%%~nxf" >nul
            echo [COPY] %%~nxf -> !HISTORY_TIMESTAMP_FOLDER!
        )
    )
)
endlocal
exit /b

REM ========================================
REM ========== PUSH TO SERVER ==============
REM ========================================
:PUSH
set "LAST_DEPLOY="

REM Lấy thư mục deploy-* mới nhất
for /f "delims=" %%d in ('dir /b /ad /o-d "%HISTORY_DIR%\deploy-*" 2^>nul') do (
    if "%LAST_DEPLOY%"=="" (
        set "LAST_DEPLOY=%HISTORY_DIR%\%%d"
    )
)


if "%LAST_DEPLOY%"=="" (
    echo [ERROR] Không tìm thấy deploy folder trong %HISTORY_DIR%
    exit /b 1
)

set "WINSCP_CMD=winscp_commands.txt"

REM Ghi script cho WinSCP
(
    echo option batch on
    echo option confirm off
    echo open %WINSCP_PROTOCOL%://%SERVER_USER%:%SERVER_PASS%@%SERVER_IP%
    echo lcd "%LAST_DEPLOY%"
    echo cd "%SERVER_DEST_PATH%"
    echo put *
    echo exit
) > "%WINSCP_CMD%"

echo =============================================
echo [PUSH] Upload từ "%LAST_DEPLOY%" lên server %SERVER_IP%
echo =============================================

"%WINSCP_PATH%" /script="%WINSCP_CMD%"

if exist "%WINSCP_CMD%" del "%WINSCP_CMD%"
echo [DONE] Push completed.
exit /b


REM ========================================
REM ========== HELP ========================
REM ========================================
:HELP
echo =============================================
echo [HELP] Danh sách lệnh hỗ trợ:
echo ---------------------------------------------
echo   deploy.bat check
echo       - Kiểm tra modules trong pom cha
echo       - Kiểm tra sự tồn tại của pom.xml và file JAR
echo.
echo   deploy.bat install [--with-parent]
echo       - Thực hiện mvn clean install cho các module con
echo       - Copy JAR vào thư mục %DEPLOY_FOLDER%
echo       - Nếu có --with-parent thì build cả parent POM
echo.
echo   deploy.bat push
echo       - Upload JARs trong thư mục deploy-* mới nhất
echo       - Sử dụng WinSCP để đẩy lên server
echo.
echo   deploy.bat -h / deploy.bat help
echo       - Hiển thị hướng dẫn sử dụng
echo =============================================
exit /b
