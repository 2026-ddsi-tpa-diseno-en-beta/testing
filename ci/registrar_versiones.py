"""Record the commits actually checked out by CI, including manually selected refs."""
import json
from pathlib import Path
import subprocess
import sys


def main():
    output=Path(sys.argv[1])
    versions={}
    for repository in sys.argv[2:]:
        sha=subprocess.check_output(['git','-C',repository,'rev-parse','HEAD'],text=True).strip()
        versions[repository]={'commit':sha}
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(versions,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(versions,ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()
