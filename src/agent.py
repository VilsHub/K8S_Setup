from fastapi import FastAPI, HTTPException
import os
import tempfile
from pathlib import Path

app             = FastAPI()
NODE_NAME       = os.environ.get("NODE_NAME")
HOST_MOUNT      = "/host-scripts/k8s/tool"
UPGRADE_FLAG    = f"{HOST_MOUNT}/kube-upgrade-target"
UPGRADE_STAGE   = f"{HOST_MOUNT}/kube-upgrade-stage"
UNINSTALL_FLAG  = f"{HOST_MOUNT}/uninstall"
ERROR_LOG       = f"{HOST_MOUNT}/error_log"

@app.get("/health")
def health():
    return {"status": "ok", "node": NODE_NAME}

@app.get("/upgrade/status")
def upgrade():
    try:
        # read current stage
        data = Path(UPGRADE_STAGE).read_text()
        log = Path(ERROR_LOG).read_text() if Path(ERROR_LOG).exists() else ""

        return {"status": "ok", "upgrade_status": data, "log": log }
    except FileNotFoundError as e:
        raise HTTPException(status_code=500, detail=str(e))
    
@app.post("/upgrade/node/{version}")
def upgrade(version: str):
    try:
        dir_path = os.path.dirname(UPGRADE_FLAG)
        content = f"""upgrade=yes
        version={version}
        """

        # atomic write
        fd, tmp = tempfile.mkstemp(dir=dir_path)
        with os.fdopen(fd, "w") as f:
            f.write(content)

        os.replace(tmp, UPGRADE_FLAG)
        print (f"Upgrade task recieved for version {version}")
        return {
            "status": "upgrade-signaled",
            "version": version
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    
@app.post("/uninstall")
def uninstall():
    try:
        with open(UNINSTALL_FLAG, "a"):
            pass
        print (f"Uninstall task recieved")
        return {
            "status": "ok"
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))