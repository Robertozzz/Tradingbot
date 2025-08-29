# app/system_control.py
from fastapi import APIRouter, Body, HTTPException
import subprocess, shlex

router = APIRouter(prefix="/system", tags=["system"])

def _sudo(cmd: str):
    return subprocess.run(shlex.split(f"sudo {cmd}"),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

@router.post("/control")
def system_control(payload: dict = Body(...)):
    module = (payload.get("module") or "").lower()
    action = (payload.get("action") or "").lower()
    if module != "ibgateway" or action not in ("start","stop","restart"):
        raise HTTPException(400, "module must be 'ibgateway' and action one of start|stop|restart")
    r = _sudo(f"systemctl {action} xpra-ibgateway-main.service")
    if r.returncode != 0:
        raise HTTPException(500, r.stderr.strip() or r.stdout.strip() or "systemctl failed")
    return {"ok": True, "action": action}
