-- expect: Can't find an implementation for InPage 4093 4
-- A 32-bit read whose last byte is past the end of the 4096-byte page.
import IdrisQL.Storage.Format
import IdrisQL.Storage.Page

pastTheEnd : Page -> IO Int
pastTheEnd p = getU32 p 4093
