#!/usr/bin/env python3
"""校验当前 Spec Kit 功能文档的结构、中文标题和需求追踪。"""
import json
import re
from pathlib import Path


def validate(root: Path) -> dict:
    state = json.loads((root / '.specify/feature.json').read_text())
    feature = (root / state['feature_directory']).resolve()
    if not feature.is_relative_to(root.resolve()):
        raise ValueError('功能目录必须位于项目内。')
    required = ['spec.md', 'plan.md', 'research.md', 'data-model.md', 'quickstart.md',
                'tasks.md', 'contracts/backend-api.md', 'contracts/tools-mcp.md', 'contracts/rag-lifecycle.md', 'checklists/requirements.md']
    errors = []
    texts = {}
    for name in required:
        path = feature / name
        if not path.is_file() or not path.read_text().strip():
            errors.append(f'缺少或为空：{name}')
            continue
        text = path.read_text()
        texts[name] = text
        if re.search(r'NEEDS CLARIFICATION|\$ARGUMENTS|\[FEATURE NAME\]|\[PROJECT_NAME\]|TODO\(|TXXX', text):
            errors.append(f'存在未完成模板标记：{name}')
        in_fence = False
        for line in text.splitlines():
            if line.startswith('```'):
                in_fence = not in_fence
            if not in_fence and line.startswith('#') and not re.search(r'[\u4e00-\u9fff]', line):
                errors.append(f'标题未使用中文：{name}: {line}')
        for target in re.findall(r'\]\(([^)\n]+)\)', text):
            if '://' in target or target.startswith('#'):
                continue
            if not (path.parent / target.split('#')[0]).exists():
                errors.append(f'本地链接不存在：{name}: {target}')
    spec = texts.get('spec.md', '')
    tasks = texts.get('tasks.md', '')
    task_rows = re.findall(r'^- \[([ xX])\] (T\d{3})(?: \[P\])?(?: \[US\d+\])? (.+)$', tasks, re.M)
    ids = [row[1] for row in task_rows]
    expected = [f'T{i:03}' for i in range(1, len(ids) + 1)]
    if ids != expected or not ids:
        errors.append('任务 ID 必须从 T001 连续编号且不能重复。')
    for _, task_id, description in task_rows:
        if not re.search(r'(?:backend/|Sources/|Tests/|Scripts/|specs/|README\.md|VALIDATION\.md)', description):
            errors.append(f'任务缺少明确文件路径：{task_id}')
    requirements = sorted(set(re.findall(r'\*\*((?:FR|SC)-\d{3})\*\*', spec)))
    covered = 0
    for requirement in requirements:
        match = re.search(r'^\| ' + requirement + r' \| ([^\n]+)\|$', tasks, re.M)
        linked = re.findall(r'T\d{3}', match[1]) if match else []
        if not linked or any(task_id not in ids for task_id in linked):
            errors.append(f'需求未关联有效任务：{requirement}')
        else:
            covered += 1
    for section in ['用户场景与验收', '功能需求', '关键实体', '成功标准', '假设与默认约定']:
        if section not in spec:
            errors.append(f'规格缺少章节：{section}')
    checklist = texts.get('checklists/requirements.md', '')
    if '- [ ]' in checklist:
        errors.append('规格质量清单仍有未通过项。')
    if errors:
        raise ValueError('\n'.join(errors))
    return {'状态': '通过', '文档数': len(required), '需求与成功标准数': len(requirements),
            '已覆盖数': covered, '任务数': len(ids),
            '已完成任务数': sum(row[0].lower() == 'x' for row in task_rows)}


if __name__ == '__main__':
    try:
        print(json.dumps(validate(Path(__file__).resolve().parent.parent), ensure_ascii=False))
    except (OSError, ValueError, KeyError) as error:
        raise SystemExit(f'文档检查未通过：{error}')
