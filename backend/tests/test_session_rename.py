"""合成话题：手动命名、持久化与旧库兼容，不接触正式资料。"""
import pytest

from interview_backend.database import Database
from interview_backend.legacy import initialize_database


def test_rename_persists_without_changing_history_or_other_sessions(client):
    session = client.post('/api/v1/sessions', json={}).json()['id']
    other = client.post('/api/v1/sessions', json={'title': '另一个话题'}).json()['id']
    db = client.app.state.database
    with db.transaction(True) as c:
        c.execute('INSERT INTO messages VALUES(?,?,?,?,?,?)', ('synthetic-message', session, 'user', '合成历史', '{}', 1))
    history = client.get('/api/v1/sessions/' + session).json()
    before = {item['id']: item for item in client.get('/api/v1/sessions').json()['items']}
    response = client.patch('/api/v1/sessions/' + session, json={'title': '  面试复盘 📚  '})
    assert response.status_code == 200
    assert response.json() == {'id': session, 'title': '面试复盘 📚'}
    after = {item['id']: item for item in client.get('/api/v1/sessions').json()['items']}
    assert after[session] == {**before[session], 'title': '面试复盘 📚', 'title_edited': 1}
    assert after[other] == before[other]
    assert client.get('/api/v1/sessions/' + session).json() == history
    # 独立连接重新打开数据库，确认保存落盘。
    reopened = Database(db.path)
    try:
        with reopened.transaction() as c:
            assert c.execute('SELECT title FROM sessions WHERE id=?', (session,)).fetchone()[0] == '面试复盘 📚'
    finally:
        reopened.close()


@pytest.mark.parametrize('body', [{}, {'title': ''}, {'title': ' \n\t '}, {'title': '字' * 121}, {'title': None}, {'title': '合法', 'scope': {}}])
def test_invalid_title_keeps_saved_name(client, body):
    session = client.post('/api/v1/sessions', json={'title': '原名称'}).json()['id']
    assert client.patch('/api/v1/sessions/' + session, json=body).status_code == 422
    assert client.get('/api/v1/sessions').json()['items'][0]['title'] == '原名称'


def test_missing_session_and_unauthorized_rename(client):
    assert client.patch('/api/v1/sessions/missing', json={'title': '合法'}).status_code == 404
    session = client.post('/api/v1/sessions', json={}).json()['id']
    assert client.patch('/api/v1/sessions/' + session, json={'title': '字' * 120}).status_code == 200
    assert client.patch('/api/v1/sessions/' + session, json={'title': '未授权'}, headers={'Authorization': 'Bearer invalid'}).status_code == 401
    assert client.get('/api/v1/sessions').json()['items'][0]['title'] == '字' * 120


@pytest.mark.parametrize('manual_title', [None, '手动名称', '新对话'])
def test_first_message_respects_manual_title(client, manual_title):
    class Engine:
        async def execute(self, *args, **kwargs):
            return {'answer': '合成回答', 'claims': []}
    client.app.state.agent.engine = Engine()
    session = client.post('/api/v1/sessions', json={}).json()['id']
    if manual_title is not None:
        assert client.patch('/api/v1/sessions/' + session, json={'title': manual_title}).status_code == 200
    response = client.post('/api/v1/agent/runs', json={'session_id': session, 'instruction': '分析合成资料', 'context': {'recording_id': 'r1'}})
    assert response.status_code == 200
    assert client.get('/api/v1/sessions').json()['items'][0]['title'] == (manual_title or '分析合成资料')


def test_previous_schema_upgrade_keeps_existing_topics(client, config):
    session = client.post('/api/v1/sessions', json={'title': '既有话题', 'scope': {'synthetic': True}}).json()['id']
    db = client.app.state.database
    with db.transaction(True) as c:
        c.execute('ALTER TABLE sessions DROP COLUMN title_edited')
        c.execute('ALTER TABLE sessions DROP COLUMN deleted')
        c.execute("UPDATE alembic_version SET version_num='0004_agent_work'")
        before = dict(c.execute('SELECT * FROM sessions WHERE id=?', (session,)).fetchone())
    assert initialize_database(config).reused
    assert initialize_database(config).reused
    with db.transaction() as c:
        after = dict(c.execute('SELECT * FROM sessions WHERE id=?', (session,)).fetchone())
    assert after == {**before, 'title_edited': 0, 'deleted': 0}
    assert client.patch('/api/v1/sessions/' + session, json={'title': '升级后改名'}).status_code == 200
