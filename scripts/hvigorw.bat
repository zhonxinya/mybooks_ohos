@echo off
set "JAVA_HOME=C:\Program Files\Huawei\DevEco Studio\jbr"
set "PATH=%JAVA_HOME%\bin;%PATH%"
set "HVIGOR_HOME=C:\Program Files\Huawei\DevEco Studio\tools\hvigor"
if exist "%HVIGOR_HOME%\bin\hvigorw.bat" (
    call "%HVIGOR_HOME%\bin\hvigorw.bat" %*
) else (
    echo Error: hvigor not found at %HVIGOR_HOME%
    echo Please open project in DevEco Studio to build
    exit /b 1
)
