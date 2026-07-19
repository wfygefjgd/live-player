[app]

title = TVPlayer
package.name = tvplayer
package.domain = org.tvplayer
source.dir = .
source.include_exts = py,png,jpg,kv,atlas
version = 1.0.0
requirements = python3,kivy==2.2.1,requests,jsonstore
orientation = landscape
osx.package_name = TVPlayer
osx.bundle_identifier = org.tvplayer.tvplayer

# Android
android.api = 33
android.ndk = 25b
android.sdk = 33
android.build_tools = 33.0.2
android.minapi = 21
android.gradle_dependencies = 
android.permissions = INTERNET
android.add_src = 
android.arch = arm64-v8a,armeabi-v7a
android.private_storage_path = 
android.ndk_path = 
android.sdk_path = 
android.ndk_api = 21
android.enable_apk_aab = apk
android.allow_download_prebuilts = True

[buildozer]

log_level = 2
warn_on_root = 1

# Avoid cloning recipes
p4a.local_recipes =
p4a.branch = develop
p4a.requirements = python3,kivy
p4a.env = 

[app:ios]
ios.codesign.allowed = False
