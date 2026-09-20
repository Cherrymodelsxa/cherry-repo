"""Regenere le depot Sileo (Packages / Packages.gz / Release) avec le nouveau .deb.

Miroir de l'outil local repo_regen.py de Blaxk, generalise pour la CI : edite le
Packages EXISTANT en place (on garde le meme format et l'ordre des champs, dont
`Filename: ./debs/cherrytouch.deb`), regenere Packages.gz (mtime=0) et reconstruit
les blocs MD5Sum / SHA256 du Release en preservant son en-tete.

Lancer depuis la RACINE du depot :  python3 build/mkrepo.py
Le nouveau paquet est attendu a build/cherrytouch.deb ; sa version est lue via
dpkg-deb par le workflow et passee dans l'env NEW_VERSION.
"""
import gzip
import hashlib
import os
import re
import shutil

NEW_DEB = "build/cherrytouch.deb"
NEW_VERSION = os.environ.get("NEW_VERSION", "").strip()


def hashes(data: bytes):
    return (
        hashlib.md5(data).hexdigest(),
        hashlib.sha1(data).hexdigest(),
        hashlib.sha256(data).hexdigest(),
    )


deb = open(NEW_DEB, "rb").read()
shutil.copyfile(NEW_DEB, os.path.join("debs", "cherrytouch.deb"))
dmd5, dsha1, dsha256 = hashes(deb)
print(f"deb: {len(deb)} octets  md5={dmd5}")

pkg = open("Packages", "r", encoding="utf-8").read()
if NEW_VERSION:
    pkg = re.sub(r"(?m)^Version: .*$", f"Version: {NEW_VERSION}", pkg)
pkg = re.sub(r"(?m)^Size: \d+$", f"Size: {len(deb)}", pkg)
pkg = re.sub(r"(?m)^MD5sum: [0-9a-f]+$", f"MD5sum: {dmd5}", pkg)
pkg = re.sub(r"(?m)^SHA1: [0-9a-f]+$", f"SHA1: {dsha1}", pkg)
pkg = re.sub(r"(?m)^SHA256: [0-9a-f]+$", f"SHA256: {dsha256}", pkg)
pkg_bytes = pkg.encode("utf-8")
open("Packages", "wb").write(pkg_bytes)

# Packages.gz reproductible (mtime=0) : pas de bruit inutile dans le diff.
gz = gzip.compress(pkg_bytes, mtime=0)
open("Packages.gz", "wb").write(gz)

# Release : on garde l'en-tete existant (avant "MD5Sum:") et on recalcule les blocs.
p_md5, _, p_sha256 = hashes(pkg_bytes)
g_md5, _, g_sha256 = hashes(gz)
rel = open("Release", "r", encoding="utf-8").read()
head = rel.split("MD5Sum:")[0]
new_rel = (
    head
    + "MD5Sum:\n"
    + f" {p_md5} {len(pkg_bytes)} Packages\n"
    + f" {g_md5} {len(gz)} Packages.gz\n"
    + "SHA256:\n"
    + f" {p_sha256} {len(pkg_bytes)} Packages\n"
    + f" {g_sha256} {len(gz)} Packages.gz\n"
)
open("Release", "wb").write(new_rel.encode("utf-8"))

print("Packages:", len(pkg_bytes), "octets ; Packages.gz:", len(gz), "octets")
print(pkg.strip())
