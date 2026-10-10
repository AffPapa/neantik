(async()=>{
      const observeSpeechVoices = async (timeoutMilliseconds = 2000) => {
        // Native lists load asynchronously. Keep only a bounded count; never
        // return voice names, identifiers, locales, or synthesise speech.
        let timer;
        let listener;
        let synthesis;
        try {
          synthesis = window.speechSynthesis;
          if (!synthesis || typeof synthesis.getVoices !== 'function') {
            return { availability: 'unavailable', count: 'unavailable', observation: 'unavailable' };
          }
          const count = () => {
            const voices = synthesis.getVoices();
            if (!Array.isArray(voices)) throw new Error('Invalid voice list');
            return String(Math.min(voices.length, 256));
          };
          const initial = count();
          if (initial !== '0') return { availability: 'available', count: initial, observation: 'observed' };
          const observed = await new Promise((resolve, reject) => {
            listener = () => {
              try { resolve({ count: count(), observation: 'observed' }); }
              catch (_) { reject(new Error('Voice observation failed')); }
            };
            synthesis.addEventListener('voiceschanged', listener);
            // Close the gap between the initial read and listener setup.
            const afterSubscription = count();
            if (afterSubscription !== '0') resolve({ count: afterSubscription, observation: 'observed' });
            timer = setTimeout(() => resolve({ count: 'unavailable', observation: 'timeout' }), timeoutMilliseconds);
          });
          return { availability: 'available', ...observed };
        } catch (_) {
          return { availability: 'unavailable', count: 'unavailable', observation: 'error' };
        } finally {
          if (timer !== undefined) clearTimeout(timer);
          if (listener && synthesis && typeof synthesis.removeEventListener === 'function') {
            synthesis.removeEventListener('voiceschanged', listener);
          }
        }
      };

return {kind:'bounded-native-speech-observation',result:await observeSpeechVoices(),errors:[]};
})()