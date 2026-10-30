// Enumerate the actual signed bundle, rather than accepting an arbitrary list.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
const magic=new Set(['feedface','cefaedfe','feedfacf','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca']);
export function measureMachOClosure(app) {
  const root=fs.realpathSync(app);assert.equal(root,app);
  const contents=fs.lstatSync(path.join(root,'Contents'));assert(contents.isDirectory()&&!contents.isSymbolicLink());
  const measured={};
  function walk(directory) {
    for(const name of fs.readdirSync(directory).sort()) {
      const file=path.join(directory,name),stat=fs.lstatSync(file),relative=path.relative(root,file);
      if(stat.isSymbolicLink()) {
        assert(fs.realpathSync(file).startsWith(root+'/Contents/'),'Bundle symlink escapes Contents');continue;
      }
      if(stat.isDirectory()){walk(file);continue;}
      assert(stat.isFile(),'Unexpected runtime entry');
      const fd=fs.openSync(file,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW);
      try {
        const opened=fs.fstatSync(fd);assert(opened.ino===stat.ino&&opened.dev===stat.dev&&opened.size===stat.size,'Runtime entry changed while opened');
        const header=Buffer.alloc(4),bytes=fs.readSync(fd,header,0,4,0);
        if(bytes===4&&magic.has(header.toString('hex'))) {
          assert(stat.nlink===1,'Runtime code must not share writable hardlinks');
          measured[relative]=crypto.createHash('sha256').update(fs.readFileSync(fd)).digest('hex');
        }
      }finally{fs.closeSync(fd);}
    }
  }
  walk(path.join(root,'Contents'));return measured;
}
export function verifyMachOClosure(app,expected) {
  assert(expected&&typeof expected==='object'&&!Array.isArray(expected));
  const measured=measureMachOClosure(app);
  assert.deepEqual(Object.entries(measured).sort(),Object.entries(expected).sort(),'Missing, changed or unbound Mach-O code');
  return measured;
}
