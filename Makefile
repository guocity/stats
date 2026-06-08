APP = Stats
BUNDLE_ID = eu.exelban.$(APP)

BUILD_PATH = $(PWD)/build
APP_PATH = "$(BUILD_PATH)/$(APP).app"
ZIP_PATH = "$(BUILD_PATH)/$(APP).zip"

.SILENT: archive notarize sign prepare-dmg prepare-dSYM clean next-version check history disk smc leveldb
.PHONY: build archive notarize sign prepare-dmg prepare-dSYM clean next-version check history open smc leveldb

build: clean next-version archive notarize sign prepare-dmg prepare-dSYM open

next-patch-version:
	@python3 Scripts/increment_version.py

release: next-patch-version build
	@versionNumber=$$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$(PWD)/build/Stats.app/Contents/Info.plist") ;\
	echo "Publishing release v$$versionNumber to guocity/stats..." ;\
	gh release create "v$$versionNumber" $(PWD)/Stats.dmg --repo guocity/stats --title "v$$versionNumber" --notes "Release v$$versionNumber"


# --- MAIN WORLFLOW FUNCTIONS --- #

archive: clean
	osascript -e 'display notification "Exporting application archive..." with title "Build the Stats"'
	echo "Exporting application archive..."

	xcodebuild \
  		-scheme $(APP) \
  		-destination 'platform=OS X,arch=x86_64' \
  		-configuration Release archive \
  		-archivePath $(BUILD_PATH)/$(APP).xcarchive

	echo "Application built, starting the export archive..."

	xcodebuild -exportArchive \
  		-exportOptionsPlist "$(PWD)/exportOptions.plist" \
  		-archivePath $(BUILD_PATH)/$(APP).xcarchive \
  		-exportPath $(BUILD_PATH)

	ditto -c -k --keepParent $(APP_PATH) $(ZIP_PATH)

	echo "Project archived successfully"

notarize:
	osascript -e 'display notification "Submitting app for notarization..." with title "Build the Stats"'
	echo "Submitting app for notarization..."

	xcrun notarytool submit --keychain-profile "AC_PASSWORD" --wait $(ZIP_PATH)

	echo "Stats successfully notarized"

sign:
	osascript -e 'display notification "Stampling the Stats..." with title "Build the Stats"'
	echo "Going to staple an application..."

	xcrun stapler staple $(APP_PATH)
	spctl -a -t exec -vvv $(APP_PATH)

	osascript -e 'display notification "Stats successfully stapled" with title "Build the Stats"'
	echo "Stats successfully stapled"

prepare-dmg:
	echo "Creating disk image..."
	rm -rf $(BUILD_PATH)/dmg
	mkdir -p $(BUILD_PATH)/dmg
	ditto $(APP_PATH) "$(BUILD_PATH)/dmg/$(APP).app"
	ln -s /Applications $(BUILD_PATH)/dmg/Applications
	rm -f $(PWD)/$(APP).dmg
	hdiutil create \
	    -volname $(APP) \
	    -srcfolder $(BUILD_PATH)/dmg \
	    -fs HFS+ \
	    -format UDZO \
	    -ov \
	    $(PWD)/$(APP).dmg
	rm -rf $(BUILD_PATH)/dmg
	echo "Created $(PWD)/$(APP).dmg"

prepare-dSYM:
	echo "Zipping dSYMs..."
	cd $(BUILD_PATH)/Stats.xcarchive/dSYMs && zip -r $(PWD)/dSYMs.zip .
	echo "Created zip with dSYMs"

# --- HELPERS --- #

clean:
	rm -rf $(BUILD_PATH)
	if [ -a $(PWD)/dSYMs.zip ]; then rm $(PWD)/dSYMs.zip; fi;
	if [ -a $(PWD)/Stats.dmg ]; then rm $(PWD)/Stats.dmg; fi;

next-version:
	versionNumber=$$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$(PWD)/Stats/Supporting Files/Info.plist") ;\
	echo "Actual version is: $$versionNumber" ;\
	versionNumber=$$((versionNumber + 1)) ;\
	echo "Next version is: $$versionNumber" ;\
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$versionNumber" "$(PWD)/Stats/Supporting Files/Info.plist" ;\

check:
	xcrun notarytool log 2d0045cc-8f0d-4f4c-ba6f-728895fd064a --keychain-profile "AC_PASSWORD"

history:
	xcrun notarytool history --keychain-profile "AC_PASSWORD"

open:
	osascript -e 'display notification "Stats signed and ready for distribution" with title "Build the Stats"'
	echo "Opening working folder..."
	open $(PWD)

smc:
	$(MAKE) --directory=./smc
	open $(PWD)/smc

leveldb:
	if [ ! -d $(PWD)/leveldb-source ]; then \
		git clone --recurse-submodules https://github.com/google/leveldb.git leveldb-source; \
	fi
	mkdir -p $(PWD)/leveldb-source/build
	cd $(PWD)/leveldb-source/build && cmake -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" -DCMAKE_BUILD_TYPE=Release .. && cmake --build .
	cp $(PWD)/leveldb-source/build/libleveldb.a $(PWD)/Kit/lldb/libleveldb.a
	rm -rf $(PWD)/leveldb-source