#!/usr/bin/env python3
"""Compare the pinned local punctuation backend on synthetic and optional local transcript samples.

The output artifact may contain private transcript text; keep it outside Git.
This script only starts local executables and never makes a network request.
"""
import argparse
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
MARKS = set('，。？！、：；,.?!:;')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', type=pathlib.Path, default=ROOT / 'Models/punctuation.int8.onnx')
    parser.add_argument('--events', type=pathlib.Path, action='append', default=[], help='Optional local AudioWorker JSONL excerpts')
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / 'TestArtifacts/punctuation-evaluation.json')
    args = parser.parse_args()
    examples = [
        ('连接技术英文', '我们使用 AI coding 代码生成平台实现多 agent 工作流把人工从重复编码挪到用力定义和关键 review 上'),
        ('问答边界', '你为什么选择这个方案因为它可以在本地运行不需要上传录音'),
        ('长句列举', '其中最核心的是 AI coding 代码生成平台主要解决三件事理解规则重复编码回归验证'),
        ('纯英文（产品使用规则回退）', 'We use SwiftUI and AVFoundation to build a local audio reader'),
    ]
    for path in args.events:
        for line in path.read_text().splitlines():
            event = json.loads(line)
            if event.get('kind') == 'transcript':
                examples.append((path.name, ''.join(s.get('original', '') for s in event.get('segments', [])[:15])))
    results = []
    for name, text in examples:
        started = time.monotonic()
        result = subprocess.run([
            str(ROOT / '.runtime/tools/sherpa/bin/sherpa-onnx-offline-punctuation'),
            '--print-args=false', '--ct-transformer=' + str(args.model), text
        ], capture_output=True, text=True, check=True)
        output = result.stdout.strip()
        normalize = lambda value: ''.join(c for c in value if c not in MARKS and not c.isspace())
        results.append(dict(case=name, input=text, output=output,
                            words_preserved=normalize(text) == normalize(output),
                            elapsed_seconds=round(time.monotonic() - started, 3)))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, ensure_ascii=False, indent=2))
    print(f'本地评估 {len(results)} 个样本，词语一致 {sum(r["words_preserved"] for r in results)} 个。')
    print('结果已保存到本地验收文件；此结果不代表人工标点准确率。')


if __name__ == '__main__':
    main()
