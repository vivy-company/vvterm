//
//  ghostty-bridging-header.h
//  VivyTerm
//
//  Bridging header to expose C APIs to Swift
//

#ifndef ghostty_bridging_header_h
#define ghostty_bridging_header_h

// Import the main Ghostty C API
// Note: ghostty.h already includes all necessary definitions
// Do NOT include ghostty/vt.h as it causes duplicate enum definitions
#import "../Vendor/libghostty/include/ghostty.h"

// Import libssh2 for SSH connections
// Uses header search paths configured in Xcode build settings
#include <libssh2.h>
#include <libssh2_sftp.h>

#endif /* ghostty_bridging_header_h */
