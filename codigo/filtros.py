#!/usr/bin/env python3
# Convierte las listas de uBlock Origin Lite (formato declarativeNetRequest de Chrome/Safari)
# al formato de bloqueador de contenido de WebKit, que usa el navegador de "Explorar fondos".
# Uso: filtros.py <carpeta rulesets/main de uBOLite> <carpeta de salida>
import json
import re
import sys
from pathlib import Path

LISTAS = ["ublock-filters", "easylist", "easyprivacy"]
MAX_POR_ARCHIVO = 45000  # WebKit admite hasta 50.000 reglas por lista

TIPOS = {
    "main_frame": "document", "sub_frame": "document", "script": "script", "image": "image",
    "stylesheet": "style-sheet", "font": "font", "media": "media", "xmlhttprequest": "fetch",
    "websocket": "websocket", "ping": "ping", "other": "other", "object": "other",
}
SEPARADOR = "[^-a-zA-Z0-9_.%]"


def a_regex(f):
    """Traduce un urlFilter de DNR (||, |, ^, *) a la expresión regular que entiende WebKit."""
    r = ""
    if f.startswith("||"):
        r, f = r"^[^:]+://+([^/]+\.)?", f[2:]
    elif f.startswith("|"):
        r, f = "^", f[1:]
    fin = f.endswith("|")
    if fin:
        f = f[:-1]
    for i, c in enumerate(f):
        if c == "*":
            r += ".*"
        elif c == "^":
            r += "(" + SEPARADOR + ".*)?$" if i == len(f) - 1 else SEPARADOR
        elif c.isalnum() or c in "-_/:=&%,~@":
            r += c
        elif ord(c) > 127:
            return None
        else:
            r += "\\" + c
    if fin and not r.endswith("$"):
        r += "$"
    return r if r else ".*"


def regla(cond, accion):
    filtro = cond.get("urlFilter")
    if "regexFilter" in cond or (filtro is None and "requestDomains" not in cond):
        return []
    disparo = {}
    if "resourceTypes" in cond:
        tipos = sorted({TIPOS[t] for t in cond["resourceTypes"] if t in TIPOS})
        if not tipos:
            return []
        disparo["resource-type"] = tipos
    if cond.get("domainType") == "thirdParty":
        disparo["load-type"] = ["third-party"]
    elif cond.get("domainType") == "firstParty":
        disparo["load-type"] = ["first-party"]
    if "initiatorDomains" in cond:
        disparo["if-domain"] = ["*" + d for d in cond["initiatorDomains"]]
    elif "excludedInitiatorDomains" in cond:
        disparo["unless-domain"] = ["*" + d for d in cond["excludedInitiatorDomains"]]
    filtros = [filtro] if filtro else ["||" + d + "^" for d in cond["requestDomains"][:200]]
    salida = []
    for f in filtros:
        r = a_regex(f)
        if r is None:
            continue
        salida.append({"trigger": {"url-filter": r, **disparo}, "action": {"type": accion}})
    return salida


def main():
    origen, destino = Path(sys.argv[1]), Path(sys.argv[2])
    destino.mkdir(parents=True, exist_ok=True)
    bloqueos, permisos = [], []
    for nombre in LISTAS:
        for r in json.loads((origen / f"{nombre}.json").read_text()):
            tipo = r["action"]["type"]
            if tipo == "block":
                bloqueos += regla(r["condition"], "block")
            elif tipo in ("allow", "allowAllRequests"):
                permisos += regla(r["condition"], "ignore-previous-rules")
    for viejo in destino.glob("filtros-*.json"):
        viejo.unlink()
    trozo = MAX_POR_ARCHIVO - len(permisos)
    for n, i in enumerate(range(0, len(bloqueos), trozo)):
        lista = bloqueos[i:i + trozo] + permisos
        (destino / f"filtros-{n + 1}.json").write_text(json.dumps(lista, separators=(",", ":")))
    print(f"{len(bloqueos)} bloqueos y {len(permisos)} excepciones")


if __name__ == "__main__":
    main()
