from pydantic import BaseModel, ConfigDict, Field

from interview_backend import schemas
from interview_backend.tools.registry import ToolRegistry, ToolSpec


class Pagination(BaseModel):
    model_config = ConfigDict(extra='forbid')
    offset: int = Field(default=0, ge=0, description='跳过的记录数')
    limit: int = Field(default=50, ge=1, le=200, description='本次最多返回的记录数')


class RecordingReference(BaseModel):
    model_config = ConfigDict(extra='forbid')
    recording_id: str = Field(min_length=1, description='录音资料的稳定标识')


class SegmentQuery(Pagination):
    run_id: str = Field(min_length=1, description='转写版本的稳定标识')


def build_catalog(repository):
    registry = ToolRegistry()
    registry.register(ToolSpec(tool_id='library.list_recordings', version='1.0', title='列出资料',
        description='按导入时间分页列出资料，不把导入时间当作实际面试日期。',
        input_model=Pagination, output_model=schemas.Page[schemas.Recording],
        handler=lambda args, context: repository.recordings(args.offset, args.limit)))
    registry.register(ToolSpec(tool_id='library.get_recording', version='1.0', title='读取资料信息',
        description='按资料标识读取名称、处理状态和元信息。',
        input_model=RecordingReference, output_model=schemas.Recording,
        handler=lambda args, context: repository.recording(args.recording_id)))
    registry.register(ToolSpec(tool_id='transcript.list_segments', version='1.0', title='读取转写片段',
        description='按版本分页读取片段，保留原稿、校对、说话人与时间位置。',
        input_model=SegmentQuery, output_model=schemas.Page[schemas.Segment],
        handler=lambda args, context: repository.segments(args.run_id, args.offset, args.limit)))
    return registry
