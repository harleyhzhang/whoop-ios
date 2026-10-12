import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
RECORD = (
    "# synthetic\nWHOOP_IOS_BEARER_TOKEN=synthetic-a==\nWHOOP_COGNITO_REFRESH_TOKEN=synthetic-r\n"
)


@pytest.mark.parametrize(
    "record", [RECORD, RECORD.encode().hex() + "\n", (RECORD + "\0").encode().hex()]
)
def test_archive_reads_env_and_keychain_hex_without_losing_token_padding(record: str) -> None:
    script = """
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {parseTokenRecord} from './archive/whoop_token_record.mjs';
assert.deepEqual(parseTokenRecord(fs.readFileSync(0, 'utf8')), {
  WHOOP_IOS_BEARER_TOKEN: 'synthetic-a==',
  WHOOP_COGNITO_REFRESH_TOKEN: 'synthetic-r',
});
"""
    subprocess.run(
        ["node", "--input-type=module", "-e", script],
        cwd=REPO,
        input=record,
        text=True,
        capture_output=True,
        check=True,
        timeout=10,
    )
