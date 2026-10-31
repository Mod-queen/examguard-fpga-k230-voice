"""Current-user encrypted local review password, independent of model keys."""
import base64
import json
import os
from pathlib import Path
import secrets
import tempfile

from .agent_settings import _crypt

SETTINGS_PATH=Path(__file__).resolve().parents[1]/'.private'/'agent_web_password.json'

def generate_password():
    return secrets.token_urlsafe(15)

def validate_password(password):
    if not isinstance(password,str) or not 8<=len(password)<=128:
        raise ValueError('网页访问密码需要8到128位')
    return password

def load_web_password(path=None):
    path=Path(path) if path is not None else SETTINGS_PATH
    if not path.exists():return ''
    try:
        if path.stat().st_size>8192:raise ValueError('large')
        value=json.loads(path.read_text(encoding='utf-8'))
        if value.get('version')!=1 or value.get('protection')!='windows-dpapi-current-user':
            raise ValueError('format')
        return validate_password(_crypt(base64.b64decode(value['password_protected'],validate=True),decrypt=True).decode('utf-8'))
    except (OSError,ValueError,TypeError,KeyError):
        return ''

def save_web_password(password,path=None):
    validate_password(password)
    value=dict(version=1,protection='windows-dpapi-current-user',
               password_protected=base64.b64encode(_crypt(password.encode('utf-8'))).decode('ascii'))
    path=Path(path) if path is not None else SETTINGS_PATH
    path.parent.mkdir(parents=True,exist_ok=True)
    temporary=None
    try:
        with tempfile.NamedTemporaryFile(mode='w',encoding='utf-8',dir=path.parent,
                                         prefix='.web-password-',suffix='.tmp',delete=False) as f:
            temporary=Path(f.name)
            json.dump(value,f,indent=2)
        os.replace(temporary,path)
    finally:
        if temporary is not None:temporary.unlink(missing_ok=True)
