"""业务库中的恢复日志；模型等待期间不持有事务。"""
import json
from interview_backend.services.common import encode


class WorkLog:
    def __init__(self, database, run_id): self.database, self.run_id = database, run_id

    def get(self, key):
        with self.database.transaction() as c:
            row = c.execute('SELECT payload FROM agent_work WHERE run_id=? AND step_key=?', (self.run_id, key)).fetchone()
            return json.loads(row[0]) if row else None

    def save(self, key, payload):
        with self.database.transaction(True) as c:
            c.execute('INSERT INTO agent_work VALUES(?,?,?) ON CONFLICT(run_id,step_key) DO UPDATE SET payload=excluded.payload',
                      (self.run_id, key, encode(payload)))

    def discard(self, key):
        with self.database.transaction(True) as c:
            c.execute('DELETE FROM agent_work WHERE run_id=? AND step_key=?', (self.run_id, key))

    async def model(self, key, bound, messages):
        from langchain_core.messages import AIMessage
        cached = self.get(key)
        if cached is not None: return AIMessage.model_validate(cached)
        response = await bound.ainvoke(messages)
        self.save(key, response.model_dump(mode='json'))
        return response
