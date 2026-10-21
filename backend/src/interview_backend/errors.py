"""可对外返回的稳定业务错误，不携带私人正文或底层 SQL。"""


class DomainError(Exception):
    def __init__(self, code: str, message: str, status_code: int = 400):
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code


def error_body(code: str, message: str) -> dict:
    return {'error': {'code': code, 'message': message}}
