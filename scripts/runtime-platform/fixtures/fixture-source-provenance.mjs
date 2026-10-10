// Research receipt provenance only. This does not qualify a release artifact.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';

const home=path.dirname(fileURLToPath(import.meta.url));
export function fixtureSourceProvenance(files, root=home) {
  assert(Array.isArray(files)&&files.length>0&&files.length<=32);
  const realRoot=fs.realpathSync(root);
  const entries=files.map(file=>{
    const absolute=file instanceof URL?fileURLToPath(file):file;
    assert(path.isAbsolute(absolute));
    const relative=path.relative(realRoot,absolute);
    assert(relative&&!relative.startsWith('..'+path.sep)&&relative!=='..'&&!path.isAbsolute(relative));
    // Hash a real regular file under this fixture directory, never a secret
    // reached through a static symlink. Check components before opening.
    // This is a fixture stamp, not a descriptor-based hostile-tree boundary.
    let cursor=realRoot;
    for(const component of relative.split(path.sep)){
      cursor=path.join(cursor,component);assert(!fs.lstatSync(cursor).isSymbolicLink());
    }
    const fd=fs.openSync(absolute,fs.constants.O_RDONLY|fs.constants.O_NOFOLLOW|fs.constants.O_NONBLOCK);
    try {
      const before=fs.fstatSync(fd);assert(before.isFile()&&before.size<=4*1024*1024);
      const data=fs.readFileSync(fd),after=fs.fstatSync(fd),current=fs.lstatSync(absolute);
      assert.equal(data.length,before.size);
      for(const key of ['dev','ino','size','mtimeMs','ctimeMs'])assert.equal(before[key],after[key]);
      assert(current.isFile()&&!current.isSymbolicLink()&&current.dev===before.dev&&current.ino===before.ino);
      return {path:relative.split(path.sep).join('/'),bytes:data.length,sha256:crypto.createHash('sha256').update(data).digest('hex')};
    } finally {fs.closeSync(fd);}
  }).sort((a,b)=>a.path.localeCompare(b.path,'en'));
  assert.equal(new Set(entries.map(e=>e.path)).size,entries.length);
  return {schemaVersion:1,files:entries,manifestSHA256:crypto.createHash('sha256').update(JSON.stringify(entries)).digest('hex')};
}

export function assertFixtureSourcesUnchanged(before,files,root=home){
  assert.deepEqual(fixtureSourceProvenance(files,root),before,'Fixture inputs changed during the observation');
}

export function preserveFixtureSources(proof,root=home){
  const files=proof.files.map(entry=>path.join(root,entry.path));
  assertFixtureSourcesUnchanged(proof,files,root);
  const archive=path.join(root,'fixture-source-archive');
  for(const dir of [archive,path.join(archive,'blobs'),path.join(archive,'manifests')]){
    if(!fs.existsSync(dir))fs.mkdirSync(dir,{mode:0o700});
    const stat=fs.lstatSync(dir);assert(stat.isDirectory()&&!stat.isSymbolicLink());
  }
  function immutable(target,data){
    if(fs.existsSync(target)){
      const stat=fs.lstatSync(target);assert(stat.isFile()&&!stat.isSymbolicLink()&&stat.size===data.length);
      assert(fs.readFileSync(target).equals(data),'Preserved fixture source was changed');return;
    }
    const temporary=path.join(path.dirname(target),'.pending-'+crypto.randomBytes(16).toString('hex'));
    const fd=fs.openSync(temporary,fs.constants.O_WRONLY|fs.constants.O_CREAT|fs.constants.O_EXCL,0o600);
    try{fs.writeFileSync(fd,data);fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
    try{fs.linkSync(temporary,target);}finally{fs.unlinkSync(temporary);}
  }
  for(const entry of proof.files){
    const data=fs.readFileSync(path.join(root,entry.path));
    assert.equal(data.length,entry.bytes);assert.equal(crypto.createHash('sha256').update(data).digest('hex'),entry.sha256);
    immutable(path.join(archive,'blobs',entry.sha256),data);
  }
  immutable(path.join(archive,'manifests',proof.manifestSHA256+'.json'),Buffer.from(JSON.stringify(proof,null,2)+'\n'));
  // Source snapshots may contain local research implementation paths. They
  // are private evidence, never automatically copied into a public release.
  return {manifestSHA256:proof.manifestSHA256,privateResearchArchive:true,notForAutomaticReleasePackaging:true};
}

if(process.argv[1]===fileURLToPath(import.meta.url)&&process.argv[2]==='--self-test'){
  const root=fs.mkdtempSync('/private/tmp/neantik-fixture-source-');
  try {
    const file=path.join(root,'owned.js');fs.writeFileSync(file,'owned fixture');
    const proof=fixtureSourceProvenance([file],root);assertFixtureSourcesUnchanged(proof,[file],root);
    assert(!JSON.stringify(proof).includes(root));
    const preserved=preserveFixtureSources(proof,root);assert.equal(preserved.manifestSHA256,proof.manifestSHA256);
    preserveFixtureSources(proof,root);
    const blob=path.join(root,'fixture-source-archive','blobs',proof.files[0].sha256);
    fs.writeFileSync(blob,'bad fixture source');assert.throws(()=>preserveFixtureSources(proof,root));
    fs.writeFileSync(file,'changed fixture');assert.throws(()=>assertFixtureSourcesUnchanged(proof,[file],root));
    assert.throws(()=>fixtureSourceProvenance([file,file],root));
    assert.throws(()=>fixtureSourceProvenance([root],root));
    assert.throws(()=>fixtureSourceProvenance([fileURLToPath(import.meta.url)],root));
    const link=path.join(root,'link');fs.symlinkSync(file,link);assert.throws(()=>fixtureSourceProvenance([link],root));
    const dirLink=path.join(root,'linked-dir');fs.symlinkSync(root,dirLink);assert.throws(()=>fixtureSourceProvenance([path.join(dirLink,'owned.js')],root));
    console.log(JSON.stringify({positiveControls:3,negativeControls:7,privatePathsAbsent:true,privateArchive:true,actualBrowser:false}));
  } finally {fs.rmSync(root,{recursive:true});}
}
