CREATE TABLE bee_sync_distribution_cursors (
  source_owner TEXT NOT NULL,
  feed TEXT NOT NULL,
  destination_node TEXT NOT NULL,
  cursor INTEGER NOT NULL CHECK(cursor >= 0),
  PRIMARY KEY(source_owner, feed, destination_node)
);
 