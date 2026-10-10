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
return {kind:"webgpu-observation",observation:await observeWebGPU()};})()
