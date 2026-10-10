(async()=>{ const hashText = value => { let hash=2166136261; for (const ch of value) {hash^=ch.charCodeAt(0);hash=Math.imul(hash,16777619);}return (hash>>>0).toString(16);};
      const observeWebGPU = async (timeoutMilliseconds = 5000) => {
        let timer;
        try {
          const gpu = navigator.gpu;
          if (!gpu || typeof gpu.requestAdapter !== 'function') {
            return 'api-absent';
          }
          const outcome = await Promise.race([
            Promise.resolve(gpu.requestAdapter()).then(adapter => ({ adapter })),
            new Promise(resolve => {
              timer = setTimeout(() => resolve({ timedOut: true }), timeoutMilliseconds);
            })
          ]);
          if (outcome.timedOut) return 'timeout';
          if (outcome.adapter === null) return 'adapter-null';
          if (!outcome.adapter) return 'error';
          const limits = {};
          for (const key in outcome.adapter.limits) {
            limits[key] = String(outcome.adapter.limits[key]);
          }
          // Availability and advertised capabilities are not operation proof.
          return `available:${hashText(JSON.stringify({
            features: Array.from(outcome.adapter.features || []).sort(),
            limits
          }))}`;
        } catch (_) {
          return 'error';
        } finally {
          if (timer !== undefined) clearTimeout(timer);
        }
      };
      // The historical report key is retained for wire compatibility; its
      // value describes the observed adapter result, never an inferred policy.

 const observation=await observeWebGPU();
 const data={kind:'webgpu-actual-compute-operations',observation,scope:'unconfigured native baseline only; production remains disabled',errors:[]};
 if(!observation.startsWith('available:')){data.status='unavailable';return data;}
 let device,storage,readback,invalid;
 async function bounded(p,stage){let timer;try{return await Promise.race([p,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error(stage+'Timeout')),5000);})]);}finally{clearTimeout(timer);}}
 try{
  const adapter=await bounded(navigator.gpu.requestAdapter(),'Adapter');if(!adapter)throw Error('AdapterDisappeared');
  device=await bounded(adapter.requestDevice(),'Device');
  storage=device.createBuffer({size:64,usage:GPUBufferUsage.STORAGE|GPUBufferUsage.COPY_SRC});
  readback=device.createBuffer({size:64,usage:GPUBufferUsage.COPY_DST|GPUBufferUsage.MAP_READ});
  const shader=device.createShaderModule({code:'@group(0) @binding(0) var<storage,read_write> values:array<u32>; @compute @workgroup_size(4) fn main(@builtin(global_invocation_id) id:vec3<u32>){ if(id.x<16u){values[id.x]=id.x*id.x+17u;} }'});
  const messages=await bounded(shader.getCompilationInfo(),'Compilation');data.compilationErrors=messages.messages.filter(m=>m.type==='error').length;
  if(data.compilationErrors)throw Error('ShaderCompileFailed');
  const pipeline=await bounded(device.createComputePipelineAsync({layout:'auto',compute:{module:shader,entryPoint:'main'}}),'Pipeline');
  const bind=device.createBindGroup({layout:pipeline.getBindGroupLayout(0),entries:[{binding:0,resource:{buffer:storage}}]});
  const encoder=device.createCommandEncoder(),pass=encoder.beginComputePass();pass.setPipeline(pipeline);pass.setBindGroup(0,bind);pass.dispatchWorkgroups(4);pass.end();encoder.copyBufferToBuffer(storage,0,readback,0,64);device.queue.submit([encoder.finish()]);
  await bounded(readback.mapAsync(GPUMapMode.READ),'Readback');data.values=Array.from(new Uint32Array(readback.getMappedRange()));readback.unmap();
  device.pushErrorScope('validation');invalid=device.createBuffer({size:64,usage:GPUBufferUsage.COPY_SRC});
  device.createBindGroup({layout:pipeline.getBindGroupLayout(0),entries:[{binding:0,resource:{buffer:invalid}}]});
  const refusal=await bounded(device.popErrorScope(),'InvalidBinding');data.invalidBindingControl={validationErrorObserved:refusal instanceof GPUValidationError};
  data.status='observed';
 }catch(error){data.status='error';data.errors.push(error.name);}
 finally{
  storage?.destroy();readback?.destroy();invalid?.destroy();
  if(device){const lost=device.lost;device.destroy();try{const r=await bounded(lost,'DeviceDestroy');data.deviceDestroyed=r.reason==='destroyed';}catch{data.deviceDestroyed=false;data.errors.push('DeviceDestroyUnproved');}}
 }
 return data;
})()
