"""只解析配置；构造配置和导入模块均不创建资料目录。"""
import os
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    data_dir: Path
    token: str = field(default='', repr=False)

    def __post_init__(self):
        object.__setattr__(self, 'data_dir', Path(self.data_dir).expanduser().resolve())

    @property
    def backend_dir(self) -> Path:
        return self.data_dir / 'Backend'

    @property
    def database_path(self) -> Path:
        return self.backend_dir / 'library.sqlite'

    @property
    def legacy_path(self) -> Path:
        return self.data_dir / 'library.sqlite'

    @classmethod
    def from_env(cls, data_dir: Path | None = None):
        root = data_dir or os.environ.get('INTERVIEW_AUDIO_DATA_DIR')
        return cls(data_dir=Path(root) if root else Path.home() / 'Library/Application Support/InterviewAudio',
                   token=os.environ.get('INTERVIEW_AUDIO_BACKEND_TOKEN', ''))

    def validate_service(self):
        if not self.token or not self.token.isascii() or any(c.isspace() for c in self.token):
            raise ValueError('请设置有效的本地后端会话令牌。')
