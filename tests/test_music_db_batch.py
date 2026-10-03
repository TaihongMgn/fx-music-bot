import os
import sqlite3
import tempfile
import unittest

from database import MusicDatabase, SettingsDatabase


def music(item_id, title, path):
    return {
        'id': item_id,
        'type': 'file',
        'title': title,
        'path': path,
        'keywords': title,
        'tags': [],
    }


class MusicBatchQueryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmp.name, 'music.db')
        conn = sqlite3.connect(self.db_path)
        conn.execute(
            "CREATE TABLE music ("
            "id TEXT PRIMARY KEY, type TEXT, title TEXT, keywords TEXT, "
            "metadata TEXT, tags TEXT, path TEXT, "
            "create_at DATETIME DEFAULT CURRENT_TIMESTAMP)")
        conn.execute("INSERT INTO music (id, title) VALUES ('info', 4)")
        conn.commit()
        conn.close()
        self.db = MusicDatabase(self.db_path)

    def tearDown(self):
        self.tmp.cleanup()

    def test_query_music_by_ids_returns_requested_rows_in_one_lookup(self):
        self.db.insert_music_many([
            music('a', 'Alpha', 'a.mp3'),
            music('b', 'Beta', 'b.mp3'),
            music('c', 'Gamma', 'c.mp3'),
        ])

        found = {row['id']: row for row in self.db.query_music_by_ids(['c', 'a', 'missing'])}

        self.assertEqual(set(found), {'a', 'c'})
        self.assertEqual(found['a']['title'], 'Alpha')
        self.assertEqual(found['c']['path'], 'c.mp3')

    def test_delete_music_by_ids_removes_only_those_rows(self):
        self.db.insert_music_many([
            music('a', 'Alpha', 'a.mp3'),
            music('b', 'Beta', 'b.mp3'),
        ])

        self.db.delete_music_by_ids(['a'])

        self.assertIsNone(self.db.query_music_by_id('a'))
        self.assertEqual(self.db.query_music_by_id('b')['title'], 'Beta')


class PlaylistSaveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = os.path.join(self.tmp.name, 'settings.db')
        conn = sqlite3.connect(self.db_path)
        conn.execute(
            "CREATE TABLE botamusique ("
            "section TEXT, option TEXT, value TEXT, UNIQUE(section, option))")
        conn.commit()
        conn.close()
        self.db = SettingsDatabase(self.db_path)

    def tearDown(self):
        self.tmp.cleanup()

    def test_save_playlist_replaces_the_queue_in_one_transaction(self):
        self.db.save_playlist(1, [(0, '{"id": "a"}'), (1, '{"id": "b"}')])
        self.db.save_playlist(0, [(0, '{"id": "c"}')])

        self.assertEqual(self.db.getint('playlist', 'current_index'), 0)
        saved = dict(self.db.items('playlist_item'))
        self.assertEqual(saved, {'0': '{"id": "c"}'})


if __name__ == '__main__':
    unittest.main()
