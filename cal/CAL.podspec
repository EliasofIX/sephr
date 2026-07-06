Pod::Spec.new do |s|
  s.name              = "CAL"
  s.version           = "0.1.0"
  s.summary           = "Chromium AppKit Layer — Sephr private bridge"
  s.homepage          = "https://sephr.internal"
  s.license           = { :type => "PolyForm-Noncommercial-1.0.0", :file => "../LICENSE" }
  s.author            = { "Sephr" => "team@sephr.internal" }
  s.source            = { :path => "." }

  s.platform          = :osx, "13.0"
  s.requires_arc      = true
  s.source_files      = "Sources/**/*.{h,mm,m}"
  s.public_header_files = [
    "Sources/CAL.h",
    "Sources/CALEngineBootstrap.h",
    "Sources/CALWebView.h",
    "Sources/CALTabStrip.h",
    "Sources/CALOmnibox.h",
    "Sources/CALMedia.h",
    "Sources/CALThumbnails.h",
    "Sources/CALDownloads.h",
    "Sources/CALHistory.h",
    "Sources/CALProfile.h",
    "Sources/CALExtensions.h",
  ]
  s.private_header_files = ["Sources/CALInternal.h"]

  s.vendored_frameworks = "../sephrium/build/Sephrium.framework"
  s.frameworks          = "AppKit", "Foundation", "CoreGraphics"
  s.libraries           = "c++"

  s.pod_target_xcconfig = {
    "CLANG_CXX_LANGUAGE_STANDARD" => "gnu++20",
    "CLANG_CXX_LIBRARY"           => "libc++",
    "FRAMEWORK_SEARCH_PATHS"      => "$(PODS_TARGET_SRCROOT)/../sephrium/build",
    "HEADER_SEARCH_PATHS"         => "$(PODS_TARGET_SRCROOT)/../sephrium/build/Sephrium.framework/Headers",
  }
end
