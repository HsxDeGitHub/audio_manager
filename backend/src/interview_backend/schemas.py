from typing import Generic, TypeVar
from pydantic import BaseModel, Field

T = TypeVar('T')


class Page(BaseModel, Generic[T]):
    items: list[T]
    total: int
    offset: int = 0
    limit: int = 50


class Recording(BaseModel):
    id: str
    title: str
    path: str
    bookmark: str | None
    fingerprint: str
    duration: float
    created_at: float
    state: str
    error: str | None
    speaker_count: int | None
    play_position: float
    active_run: str | None
    kind: str
    interview_date: str | None
    company: str | None
    role: str | None
    revision: int = Field(ge=1)


class TranscriptRun(BaseModel):
    id: str
    recording_id: str
    created_at: float


class Segment(BaseModel):
    id: str
    run_id: str
    start: float
    end: float
    original: str
    edited: str | None
    text: str
    speaker: int | None
    speaker_edited: bool
    needs_review: bool
    reviewed: bool


class Speaker(BaseModel):
    speaker: int
    name: str


class Draft(BaseModel):
    id: str
    run_id: str
    created_at: float
    payload: dict
