import React, { useEffect, useRef, useState } from 'react';

export function WindowsWaitlist({ lang, t, open, onClose }) {
  const [email, setEmail] = useState('');
  const [state, setState] = useState('idle');
  const [error, setError] = useState('');
  const input = useRef(null);
  const dialog = useRef(null);
  const request = useRef(null);

  useEffect(() => {
    if (open && !dialog.current.open) {
      dialog.current.showModal();
      input.current?.focus();
    } else if (!open && dialog.current.open) {
      dialog.current.close();
    }
  }, [open]);
  useEffect(() => () => request.current?.abort(), []);

  async function submit(event) {
    event.preventDefault();
    if (request.current) return;
    setState('loading');
    setError('');
    const controller = new AbortController();
    request.current = controller;
    const timeout = setTimeout(() => controller.abort(), 12000);
    try {
      const form = new FormData(event.currentTarget);
      // Submitting the clearly labeled waitlist form opts in to the launch notification.
      const response = await fetch('/api/waitlist', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: email.trim(), language: lang, consent: true, website: form.get('website') }),
        signal: controller.signal,
      });
      const result = await response.json();
      if (!response.ok || result.ok !== true) {
        const key = response.status === 429 ? 'rateLimit' : response.status === 400 ? 'invalid' : response.status === 503 ? 'unavailable' : 'failed';
        setError(t[key]);
        setState('error');
        return;
      }
      setState('success');
      setEmail('');
    } catch {
      setError(t.failed);
      setState('error');
    } finally {
      clearTimeout(timeout);
      request.current = null;
    }
  }

  return <dialog ref={dialog} id="windows-waitlist" className="windows-waitlist" aria-labelledby="waitlist-title" aria-describedby="waitlist-description" onClose={onClose} onClick={event => {
    if (event.target !== dialog.current) return;
    const bounds = dialog.current.getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) dialog.current.close();
  }}>
    <div className="waitlist-heading"><h2 id="waitlist-title">{t.title}</h2><button type="button" className="waitlist-close" onClick={() => dialog.current.close()}>{t.close}</button></div>
    <p id="waitlist-description" className="waitlist-description">{t.description}</p>
    {state === 'success' ? <p className="waitlist-success" role="status">{t.success}</p> : <form onSubmit={submit} aria-busy={state === 'loading'}>
      <label htmlFor="waitlist-email">{t.email}</label>
      <div className="waitlist-input-row"><input ref={input} id="waitlist-email" name="email" type="email" autoComplete="email" placeholder="you@example.com" required maxLength={254} value={email} onChange={event => setEmail(event.target.value)} aria-describedby="waitlist-status" disabled={state === 'loading'} /><button className="button" type="submit" disabled={state === 'loading'}>{state === 'loading' ? t.saving : t.submit}</button></div>
      <div className="waitlist-trap" aria-hidden="true"><label htmlFor="waitlist-website">Website</label><input id="waitlist-website" name="website" tabIndex={-1} autoComplete="off" /></div>
      <p id="waitlist-status" className="waitlist-error" role="status">{error}</p>
    </form>}
  </dialog>;
}
