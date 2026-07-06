DEV := DEVELOPER_DIR=/Library/Developer/CommandLineTools
# CLT 的 SwiftPM 不会自动把 Testing.framework 加入框架搜索路径,必须显式传 -F/-rpath
FW  := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TESTFLAGS := -Xswiftc -F$(FW) -Xlinker -F$(FW) -Xlinker -rpath -Xlinker $(FW)
build: ; $(DEV) swift build
test:  ; $(DEV) swift test $(TESTFLAGS)
run:   ; $(DEV) swift run PDFLabApp
bundle:; bash scripts/bundle_app.sh
dmg: bundle ; bash scripts/make_dmg.sh
