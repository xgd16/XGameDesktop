# XGameDesktop 常用任务（GNU make）。
#
# 机器上没装 make 也能用：项目自带便携版 GNU make 4.4.1（tool\make\bin\make.exe，
# 来自 SourceForge 的 ezwinports，zip sha256 前缀 fb66a02b…），根目录的 make.cmd
# 会转发过去——cmd / PowerShell 里直接 `make package` 即可；Git Bash 里用
# tool/make/bin/make.exe，或把 tool\make\bin 加进 PATH 后照常 `make`。
#
#   make             列出可用目标（默认目标）
#   make package     构建 Release 并产出安装包 dist\XGameDesktop-Setup-<版本>.exe
#   make release     只构建 Release（build\windows\x64\runner\Release）
#   make debug       构建 Debug
#   make run         以调试方式启动（flutter run -d windows）
#   make test        跑全部测试
#   make analyze     静态检查
#   make clean       清掉 Flutter 构建产物
#   make distclean   clean，并删掉 dist\ 和打包暂存目录
#
# 变量（跟在目标后面，如 `make package SKIPBUILD=1`）：
#   SKIPBUILD=1        复用已有 Release 产物，不重新构建
#   VERSION=1.2.0      覆盖安装包版本号（默认读 pubspec.yaml）
#
# 配方只用最普通的命令行，cmd.exe 和 sh 都能跑（make 在 Windows 上按 PATH 里有没有
# sh.exe 二选一）。所以这里不写 rm/cp 之类的 shell 语法。

FLUTTER ?= flutter
PWSH    ?= powershell -NoProfile -ExecutionPolicy Bypass

.DEFAULT_GOAL := help
.PHONY: help package release debug run test analyze clean distclean

help:
	@echo Targets:
	@echo   make package     build Release, then write dist/XGameDesktop-Setup-VERSION.exe
	@echo   make release     build Release only
	@echo   make debug       build Debug
	@echo   make run         run the app from source - flutter run -d windows
	@echo   make test        run all tests
	@echo   make analyze     static analysis
	@echo   make clean       flutter clean
	@echo   make distclean   clean, and remove dist/ plus the packaging staging dir
	@echo Options:
	@echo   make package SKIPBUILD=1     reuse the existing Release output
	@echo   make package VERSION=1.2.0   override the installer version

package:
	$(PWSH) -File tool/package_windows.ps1 $(if $(SKIPBUILD),-SkipBuild) $(if $(VERSION),-Version $(VERSION))

release:
	$(FLUTTER) build windows --release

debug:
	$(FLUTTER) build windows --debug

run:
	$(FLUTTER) run -d windows

test:
	$(FLUTTER) test

analyze:
	$(FLUTTER) analyze

clean:
	$(FLUTTER) clean

distclean: clean
	$(PWSH) -Command "Remove-Item -Recurse -Force dist, build/installer -ErrorAction SilentlyContinue"
