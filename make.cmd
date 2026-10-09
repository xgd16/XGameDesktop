@echo off
rem Forward to the project's own portable GNU make, so `make ...` works on a
rem machine with no make installed. In Git Bash use tool/make/bin/make.exe,
rem or put tool\make\bin on PATH and call make normally.
"%~dp0tool\make\bin\make.exe" %*
