#!/usr/bin/env python3
"""Observe exact unsigned M156 output after terminal success.

This is one input to the future dedicated M156 candidate contract. It does
not authenticate a source manifest, sign an app, or qualify runtime behavior.
Framework hashes are streamed to avoid loading large binaries into memory.
"""
from __future__ import annotations
import hashlib
import os
import plistlib
import stat
import struct
from pathlib import Path
from typing import Any
from chromium_15612_postbuild8 import require_terminal, ARGS_SHA256
from chromium_15612_generated_cache import VERSION, COMMIT, TREE, HASH, need


def observe_regular(root: Path, relative: str, maximum: int, *, buffered: bool = False) -> dict[str, Any]:
    """Retain directory anchors and reject replaced, linked or growing inputs."""
    need(root.is_absolute() and all(part not in {'.','..'} for part in root.parts) and
         isinstance(relative,str) and relative and '\x00' not in relative and
         not relative.startswith('/') and '\\' not in relative and
         all(part not in {'','.','..'} for part in relative.split('/')),
         'Real root and safe relative binary path required')
    descriptors=[os.open('/',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)]
    anchors=[]
    directory_identity=lambda s:(s.st_dev,s.st_ino,s.st_mode,s.st_uid)
    identity=lambda s:(*directory_identity(s),s.st_nlink,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
    try:
        components=list(root.parts[1:])+relative.split('/')
        for part in components[:-1]:
            parent=descriptors[-1]
            before=os.stat(part,dir_fd=parent,follow_symlinks=False)
            child=os.open(part,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,dir_fd=parent)
            descriptors.append(child)
            need(stat.S_ISDIR(before.st_mode) and directory_identity(before)==directory_identity(os.fstat(child)),
                 'Binary ancestor changed')
            anchors.append((parent,part,child,directory_identity(before)))
        parent=descriptors[-1]
        leaf=os.open(components[-1],os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
        descriptors.append(leaf);before=os.fstat(leaf)
        need(stat.S_ISREG(before.st_mode) and before.st_uid==os.getuid() and
             before.st_nlink==1 and 0<before.st_size<=maximum,'Unsafe unsigned binary input')
        hasher=hashlib.sha256();total=0;prefix=b'';data=bytearray() if buffered else None
        while total<=before.st_size:
            block=os.read(leaf,min(65536,before.st_size+1-total))
            if not block:break
            if len(prefix)<32:prefix+=block[:32-len(prefix)]
            hasher.update(block);total+=len(block)
            if data is not None:data.extend(block)
        need(total==before.st_size and identity(before)==identity(os.fstat(leaf))==
             identity(os.stat(components[-1],dir_fd=parent,follow_symlinks=False)),
             'Binary input changed during read')
        for parent,part,child,expected in anchors:
            need(expected==directory_identity(os.fstat(child))==
                 directory_identity(os.stat(part,dir_fd=parent,follow_symlinks=False)),
                 'Binary ancestor replaced during read')
        result={'bytes':total,'sha256':hasher.hexdigest(),'prefix':prefix,'mode':stat.S_IMODE(before.st_mode)}
        if data is not None:result['data']=bytes(data)
        return result
    finally:
        for descriptor in reversed(descriptors):os.close(descriptor)


def require_arm64_header(record: dict[str, Any], filetype: int) -> None:
    need(len(record['prefix'])==32,'Truncated Mach-O header')
    magic,cpu,subtype,kind,commands,command_bytes,flags,reserved=struct.unpack('<8I',record['prefix'])
    need(magic==0xfeedfacf and cpu==0x0100000c and kind==filetype and
         0<commands<=65536 and 8<=command_bytes<=record['bytes']-32,
         'Exact thin ARM64 Mach-O output required')


def observe_unsigned_candidate(app: Path,args_gn: Path,terminal: dict[str, Any],
                               source_manifest_sha256: str) -> dict[str, Any]:
    # Refuse BEFORE touching even the app directory when build is not terminal.
    require_terminal(terminal)
    need(isinstance(source_manifest_sha256,str) and HASH.fullmatch(source_manifest_sha256) is not None,
         'Caller-bound source manifest digest required')
    info_record=observe_regular(app,'Contents/Info.plist',1024*1024,buffered=True)
    info=plistlib.loads(info_record['data'])
    need(isinstance(info,dict) and info.get('CFBundleShortVersionString')==VERSION and
         info.get('CFBundleExecutable')=='NeAntik Browser','Unsigned M156 app identity differs')
    executable=observe_regular(app,'Contents/MacOS/NeAntik Browser',1024**3)
    framework=observe_regular(app,'Contents/Frameworks/NeAntik Browser Framework.framework/Versions/'+
                              VERSION+'/NeAntik Browser Framework',8*1024**3)
    require_arm64_header(executable,2);require_arm64_header(framework,6)
    need(executable['mode']&0o111 and framework['mode']&0o111,'Unsigned Mach-O execute mode missing')
    args=observe_regular(args_gn.parent,args_gn.name,1024*1024)
    need(args['sha256']==ARGS_SHA256,'Unsigned output uses unreviewed build arguments')
    return {'schemaVersion':1,'status':'unsigned-native-output-binding-only','chromiumVersion':VERSION,
            'officialChromiumBase':{'commit':COMMIT,'tree':TREE},
            'callerSourceManifestSHA256':source_manifest_sha256,
            'binaryBinding':{'candidateExecutableSHA256':executable['sha256'],
                             'candidateFrameworkSHA256':framework['sha256'],
                             'candidateInfoPlistSHA256':info_record['sha256'],
                             'argsGNSHA256':args['sha256'],'targetArchitecture':'arm64',
                             'executableBytes':executable['bytes'],'frameworkBytes':framework['bytes']},
            'sourceManifestAuthenticated':False,'nativeOutputLoadabilityVerified':False,
            'developerIDVerified':False,'runtimeQualified':False,'releaseReady':False}
