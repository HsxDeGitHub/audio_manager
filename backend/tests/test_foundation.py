import subprocess
import sys

import pytest
from fastapi.testclient import TestClient

from interview_backend.app import create_app
from interview_backend.config import Settings


def test_factory_is_lazy_and_health_does_not_expose_private_settings(config):
    app = create_app(config)
    assert not config.data_dir.exists()
    with TestClient(app) as client:
        response = client.get('/health')
        assert response.json() == {'status': 'ok', 'service': 'interview-audio-backend', 'version': '0.1.0'}
        assert config.token not in response.text
        assert str(config.data_dir) not in response.text


@pytest.mark.parametrize('authorization', [None, 'Bearer wrong-token', 'Basic arbitrary', 'Bearer'])
def test_business_api_requires_session_token(config, authorization):
    with TestClient(create_app(config)) as client:
        headers = {'Authorization': authorization} if authorization else {}
        response = client.get('/api/v1/recordings', headers=headers)
        assert response.status_code == 401
        assert response.json()['error']['code'] == 'unauthorized'
        assert config.token not in response.text


def test_missing_token_and_remote_bind_are_rejected(config):
    with pytest.raises(ValueError, match='令牌'):
        create_app(Settings(data_dir=config.data_dir, token=''))
    result = subprocess.run([sys.executable, '-m', 'interview_backend', '--data-dir', str(config.data_dir),
                             'serve', '--host', '0.0.0.0'], capture_output=True, text=True)
    assert result.returncode != 0
    assert not config.database_path.exists()


def test_environment_is_read_explicitly(monkeypatch, tmp_path):
    monkeypatch.setenv('INTERVIEW_AUDIO_DATA_DIR', str(tmp_path / 'isolated'))
    monkeypatch.setenv('INTERVIEW_AUDIO_BACKEND_TOKEN', 'fixture-key')
    settings = Settings.from_env()
    assert settings.data_dir == tmp_path / 'isolated'
    assert settings.database_path == tmp_path / 'isolated/Backend/library.sqlite'
    assert not settings.data_dir.exists()


@pytest.mark.parametrize('query', ['limit=0', 'limit=201', 'offset=-1', 'limit=private-input'])
def test_invalid_pagination_is_localized_and_does_not_echo_input(client, query):
    response = client.get('/api/v1/recordings?' + query)
    assert response.status_code == 422
    assert response.json()['error']['code'] == 'invalid_request'
    assert 'private-input' not in response.text


def test_capabilities_are_honest_and_foreign_keys_are_enabled(client):
    from sqlalchemy import text
    result = client.get('/api/v1/system/status').json()
    assert result['schema_revision'] == '0002_application'
    assert result['legacy_imported'] is True
    assert result['counts']['recordings'] == 2
    assert result['capabilities']['library_read'] is True
    for capability in ['semantic_search']:
        assert result['capabilities'][capability] is False
    with client.app.state.database.engine.connect() as connection:
        assert connection.scalar(text('PRAGMA foreign_keys')) == 1
        assert connection.scalar(text('PRAGMA journal_mode')) == 'wal'


def test_importing_package_has_no_data_side_effects(tmp_path):
    import os
    target = tmp_path / 'never-created'
    result = subprocess.run([sys.executable, '-c', 'import interview_backend.app'],
        env={**os.environ, 'INTERVIEW_AUDIO_DATA_DIR': str(target)}, capture_output=True, text=True)
    assert result.returncode == 0
    assert not target.exists()
