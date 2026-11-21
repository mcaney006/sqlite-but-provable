-- The last four bytes of a page are a valid place for a 32-bit field.
import IdrisQL.Storage.Format
import IdrisQL.Storage.Page

lastWord : Page -> IO Int
lastWord p = getU32 p 4092
