import hashlib
import uuid
from interview_backend.services.common import encode, once, require
from interview_backend.services.changesets import ChangeSetService
from interview_backend.errors import DomainError


class DocumentService:
    def __init__(self, database): self.database = database
    def get(self, identifier):
        with self.database.transaction() as c:
            row = require(c, 'documents', identifier)
            if row['removed']: raise DomainError('not_found', '材料已移除。', 404)
            return row
    def import_text(self, title, format, content, operation_id):
        if format not in {'txt','md'} or not isinstance(title,str) or not title.strip() or not isinstance(content,str) or not content.strip():
            raise DomainError('invalid_document', '只支持非空 TXT/Markdown 文本材料。', 422)
        digest = hashlib.sha256(content.encode()).hexdigest()
        with self.database.transaction(True) as c:
            def execute():
                prior = c.execute('SELECT * FROM documents WHERE digest=? AND removed=0', (digest,)).fetchone()
                if prior: return {**dict(prior), 'duplicate':True}
                identifier = str(uuid.uuid4())
                c.execute('INSERT INTO documents VALUES(?,?,?,?,?,?,0,1)', (identifier,title,format,content,content,digest))
                c.execute('INSERT INTO index_queue VALUES(?,?,1,?)', ('document',identifier,'pending'))
                return {**require(c,'documents',identifier),'duplicate':False}
            return once(c, operation_id, {'title':title,'format':format,'content':content}, execute)
    def list(self):
        with self.database.transaction() as c:
            return {'items':[dict(r) for r in c.execute('SELECT * FROM documents WHERE removed=0 ORDER BY title,id')]}
    def update(self, identifier, fields, revision, operation_id):
        return ChangeSetService(self.database).submit({'operation_id':operation_id,'targets':[{'resource_type':'document','resource_id':identifier,'expected_revision':revision,'fields':fields}]})
