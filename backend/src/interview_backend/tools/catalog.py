from pydantic import BaseModel, ConfigDict, Field

from interview_backend import schemas
from interview_backend.prompt_catalog import field_description, tool_description
from interview_backend.tools.registry import ToolRegistry, ToolSpec


class Pagination(BaseModel):
    model_config = ConfigDict(extra='forbid')
    offset: int = Field(default=0, ge=0, description=field_description('Pagination.offset'))
    limit: int = Field(default=50, ge=1, le=200, description=field_description('Pagination.limit'))


class RecordingReference(BaseModel):
    model_config = ConfigDict(extra='forbid')
    recording_id: str = Field(min_length=1, description=field_description('RecordingReference.recording_id'))


class SegmentQuery(Pagination):
    run_id: str = Field(min_length=1, description=field_description('SegmentQuery.run_id'))


def build_catalog(repository):
    registry = ToolRegistry()
    registry.register(ToolSpec(tool_id='library.list_recordings', version='1.0', title='列出资料',
        description=tool_description('library.list_recordings'),
        input_model=Pagination, output_model=schemas.Page[schemas.Recording],
        handler=lambda args, context: repository.recordings(args.offset, args.limit)))
    registry.register(ToolSpec(tool_id='library.get_recording', version='1.0', title='读取资料信息',
        description=tool_description('library.get_recording'),
        input_model=RecordingReference, output_model=schemas.Recording,
        handler=lambda args, context: repository.recording(args.recording_id)))
    registry.register(ToolSpec(tool_id='transcript.list_segments', version='1.0', title='读取转写片段',
        description=tool_description('transcript.list_segments'),
        input_model=SegmentQuery, output_model=schemas.Page[schemas.Segment],
        handler=lambda args, context: repository.segments(args.run_id, args.offset, args.limit)))
    return registry
