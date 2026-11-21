-- The library example in README.md.
import IdrisQL

main : IO ()
main = do
  Right rows <- runDB $ do
      db <- openDatabase "shop.idb" defaultOptions
      _ <- execute db "CREATE TABLE IF NOT EXISTS item (id INTEGER PRIMARY KEY, name TEXT NOT NULL)" []
      _ <- execute db "INSERT INTO item (name) VALUES (?)" [VText "kettle"]
      result <- query db "SELECT id, name FROM item WHERE name = ?" [VText "kettle"]
      rows <- fetchAll result
      closeDatabase db
      pure rows
    | Left e => putStrLn ("failed: " ++ show e)
  printLn rows
