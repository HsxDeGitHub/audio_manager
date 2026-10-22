import hashlib
import json
from interview_backend.retrieval.lexical import tokens, query
from interview_backend.retrieval.semantic import SemanticIndex
from interview_backend.services.common import version, encode
from interview_backend.services.draft_sources import draft_current
from interview_backend.services.source_validity import source_valid


class RetrievalIndex:
    def __init__(self,database,backend_dir):
        self.database = database; self.semantic = SemanticIndex(backend_dir/'Models')
        # 派生表可重建，不改变业务原文；与内容版本在同一个业务库中核对。
        with database.transaction(True) as c:
            c.execute('CREATE TABLE IF NOT EXISTS search_chunks (id TEXT PRIMARY KEY, resource_type TEXT NOT NULL, resource_id TEXT NOT NULL, revision INTEGER NOT NULL, start INTEGER NOT NULL, end INTEGER NOT NULL, line INTEGER NOT NULL, content TEXT NOT NULL, digest TEXT NOT NULL, model_version TEXT, vector BLOB)')
            c.execute('CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(chunk_id UNINDEXED,tokens,content UNINDEXED)')
    def sources(self,c):
        values = []
        for row in c.execute('SELECT s.* FROM segments s JOIN recordings r ON r.active_run=s.run_id ORDER BY s.run_id,s.start,s.id'):
            values.append(('segment',row['id'],version(c,'segment',row['id']),row['edited'] if row['edited'] is not None else row['original']))
        for row in c.execute('SELECT * FROM documents WHERE removed=0'):
            values.append(('document',row['id'],row['revision'],row['content']))
        for row in c.execute('SELECT * FROM ai_drafts'):
            if not draft_current(c, row): continue
            payload = json.loads(row['payload'])
            text = '\n\n'.join(b.get('text','') for chunk in payload.get('chunks',[]) for b in chunk.get('blocks') or [])
            if text: values.append(('draft',row['id'],version(c,'draft',row['id']),text))
        for row in c.execute("SELECT * FROM memories WHERE state='active'"):
            if not source_valid(c, {'resource_type':'memory','resource_id':row['id'],'revision':row['revision']}): continue
            values.append(('memory',row['id'],row['revision'],row['content']))
        return values
    def sync(self):
        with self.database.transaction() as c:
            sources = self.sources(c)
            indexed = {(r['resource_type'],r['resource_id'],r['revision'],r['digest'],r['model_version']) for r in c.execute('SELECT * FROM search_chunks')}
        state = self.semantic.status(); model_version = state.get('version') if state['ready'] else None
        prepared = []
        for kind,identifier,revision,text in sources:
            digest = hashlib.sha256(text.encode()).hexdigest()
            if (kind,identifier,revision,digest,model_version) in indexed: continue
            parts = self.semantic.split(text) if state['ready'] else [(i,min(i+2000,len(text)),text[i:i+2000]) for i in range(0,len(text),1800)]
            vectors = self.semantic.vectors([p[2] for p in parts]) if state['ready'] and parts else None
            prepared.append((kind,identifier,revision,digest,text,parts,vectors))
        with self.database.transaction(True) as c:
            current = {(k,i):(r,t) for k,i,r,t in self.sources(c)}
            for row in c.execute('SELECT id,resource_type,resource_id,revision FROM search_chunks').fetchall():
                item = current.get((row['resource_type'],row['resource_id']))
                if item is None or item[0] != row['revision']:
                    c.execute('DELETE FROM search_fts WHERE chunk_id=?',(row['id'],)); c.execute('DELETE FROM search_chunks WHERE id=?',(row['id'],))
            for kind,identifier,revision,digest,text,parts,vectors in prepared:
                if current.get((kind,identifier)) != (revision,text): continue
                for old in c.execute('SELECT id FROM search_chunks WHERE resource_type=? AND resource_id=?',(kind,identifier)).fetchall():
                    c.execute('DELETE FROM search_fts WHERE chunk_id=?',(old[0],))
                c.execute('DELETE FROM search_chunks WHERE resource_type=? AND resource_id=?',(kind,identifier))
                for index,(start,end,content) in enumerate(parts):
                    chunk_id = hashlib.sha256(f'{kind}:{identifier}:{revision}:{index}'.encode()).hexdigest()
                    vector = vectors[index].tobytes() if vectors is not None else None
                    c.execute('INSERT INTO search_chunks VALUES(?,?,?,?,?,?,?,?,?,?,?)',(chunk_id,kind,identifier,revision,start,end,text[:start].count('\n')+1,content,digest,model_version,vector))
                    c.execute('INSERT INTO search_fts VALUES(?,?,?)',(chunk_id,' '.join(tokens(content)),content))
                c.execute("UPDATE index_queue SET state='ready' WHERE resource_type=? AND resource_id=? AND revision=?",(kind,identifier,revision))
    def search(self,text,limit=8,allowed=None):
        if not text.strip(): return []
        self.sync(); ranks = {}; lexical = []
        if allowed is not None and not allowed: return []
        parameters = []
        clause = ''
        if allowed is not None:
            clause = ' AND (' + ' OR '.join('(c.resource_type=? AND c.resource_id=?)' for _ in allowed) + ')'
            parameters = [part for pair in sorted(allowed) for part in pair]
        with self.database.transaction() as c:
            expression = query(text)
            if expression:
                lexical = [r[0] for r in c.execute('SELECT chunk_id FROM search_fts JOIN search_chunks c ON c.id=search_fts.chunk_id WHERE search_fts MATCH ?' + clause + ' ORDER BY bm25(search_fts) LIMIT 20',[expression]+parameters)]
            literal = [r[0] for r in c.execute('SELECT c.id FROM search_chunks c WHERE instr(lower(c.content),lower(?))>0' + clause + ' LIMIT 20',[text]+parameters)]
            for i,identifier in enumerate(dict.fromkeys(literal+lexical)):
                ranks[identifier] = ranks.get(identifier,0)+1/(60+i+1)
            rows = [dict(r) for r in c.execute('SELECT c.* FROM search_chunks c WHERE 1=1' + clause,parameters)]
        if self.semantic.status()['ready'] and rows:
            import numpy as np
            q = self.semantic.vectors([text])[0]
            semantic = sorted([(r['id'],float(np.dot(q,np.frombuffer(r['vector'],dtype=np.float32)))) for r in rows if r['vector']],key=lambda r:-r[1])[:20]
            for i,(identifier,score) in enumerate(semantic): ranks[identifier] = ranks.get(identifier,0)+1/(60+i+1)
        results = []
        for row in sorted(rows,key=lambda r:-ranks.get(r['id'],0)):
            if row['id'] not in ranks or (allowed is not None and (row['resource_type'],row['resource_id']) not in allowed): continue
            with self.database.transaction() as c:
                if not source_valid(c, row): continue
            row.pop('vector'); row['score'] = ranks[row['id']]; results.append(row)
            if len(results)>=limit: break
        return results
