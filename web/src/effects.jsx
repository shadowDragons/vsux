import { useEffect, useRef } from 'react';
import './effects.css';

// Decorative only: no product or user data enters the animation.
export function HeroAtmosphere() {
  const canvas = useRef(null);

  useEffect(() => {
    const element = canvas.current;
    const context = element.getContext('2d');
    if (!context) return;
    const motion = matchMedia('(prefers-reduced-motion: reduce)');
    const compact = matchMedia('(max-width: 800px)');
    let width = 0, height = 0, frame = 0, time = 0, previous = 0;
    let visible = true;
    const pointer = { x: .5, y: .3, targetX: .5, targetY: .3 };
    const points = Array.from({ length: 48 }, (_, i) => ({
      x: ((i * 73 + 19) % 997) / 997,
      y: ((i * 137 + 67) % 991) / 991,
      speed: .3 + (i % 5) * .12,
    }));

    function draw(now) {
      frame = 0;
      const elapsed = previous ? Math.min(now - previous, 40) : 0;
      previous = now;
      if (!motion.matches) time += elapsed * .001;
      pointer.x += (pointer.targetX - pointer.x) * .045;
      pointer.y += (pointer.targetY - pointer.y) * .045;
      context.clearRect(0, 0, width, height);
      const count = compact.matches ? 20 : points.length;
      const positions = points.slice(0, count).map((point, i) => ({
        x: point.x * width + Math.sin(time * .13 * point.speed + i) * 25 + (pointer.x - .5) * (i % 3 + 1) * 12,
        y: point.y * height + Math.cos(time * .16 + i) * 20 + (pointer.y - .5) * 18,
      }));
      positions.forEach((point, i) => {
        for (let j = i + 1; j < positions.length; j++) {
          const other = positions[j];
          const distance = Math.hypot(point.x - other.x, point.y - other.y);
          if (distance > 175) continue;
          context.strokeStyle = `rgba(89, 186, 255, ${(.16 * (1 - distance / 175)).toFixed(3)})`;
          context.beginPath(); context.moveTo(point.x, point.y); context.lineTo(other.x, other.y); context.stroke();
        }
        const near = Math.hypot(point.x - pointer.x * width, point.y - pointer.y * height) < 200;
        context.fillStyle = near ? '#a7dcff' : 'rgba(89, 186, 255, .45)';
        context.beginPath(); context.arc(point.x, point.y, near ? 1.8 : 1.1, 0, Math.PI * 2); context.fill();
      });
      if (!motion.matches && !compact.matches && visible && !document.hidden) frame = requestAnimationFrame(draw);
    }
    function resume() {
      cancelAnimationFrame(frame);
      previous = 0;
      draw(performance.now());
    }
    const resize = new ResizeObserver(([entry]) => {
      ({ width, height } = entry.contentRect);
      const ratio = Math.min(devicePixelRatio || 1, 2);
      element.width = Math.round(width * ratio); element.height = Math.round(height * ratio);
      context.setTransform(ratio, 0, 0, ratio, 0, 0);
      resume();
    });
    const intersection = new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; resume(); });
    function move(event) {
      if (motion.matches || compact.matches || event.pointerType === 'touch') return;
      const rect = element.getBoundingClientRect();
      pointer.targetX = (event.clientX - rect.left) / rect.width;
      pointer.targetY = (event.clientY - rect.top) / rect.height;
    }
    const hero = element.closest('.hero');
    hero.addEventListener('pointermove', move, { passive: true });
    resize.observe(element); intersection.observe(element);
    motion.addEventListener('change', resume); compact.addEventListener('change', resume);
    document.addEventListener('visibilitychange', resume);
    return () => {
      cancelAnimationFrame(frame); resize.disconnect(); intersection.disconnect();
      hero.removeEventListener('pointermove', move);
      motion.removeEventListener('change', resume); compact.removeEventListener('change', resume);
      document.removeEventListener('visibilitychange', resume);
    };
  }, []);

  return <div className="hero-atmosphere" aria-hidden="true">
    <div className="hero-light" /><canvas ref={canvas} /><div className="perspective-grid" />
    <div className="signal-line signal-left" /><div className="signal-line signal-right" />
  </div>;
}

export function usePageEffects(root) {
  useEffect(() => {
    const site = root.current;
    const motion = matchMedia('(prefers-reduced-motion: reduce)');
    const fine = matchMedia('(hover: hover) and (pointer: fine) and (min-width: 801px)');
    const stage = site.querySelector('.product-stage');
    let frame = 0;
    const revealTargets = site.querySelectorAll('.friction > div, .features > .eyebrow, .features > h2, .features > .section-intro, .feature-grid article, .service-feature, .workflow-extras article, .philosophy > div, .open-source > div, .start > *');
    const observer = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if (entry.isIntersecting) { entry.target.classList.add('is-revealed'); observer.unobserve(entry.target); }
      });
    }, { threshold: .12, rootMargin: '0px 0px -24px 0px' });
    revealTargets.forEach(element => {
      element.classList.add('reveal');
      element.style.setProperty('--reveal-delay', `${element.closest('.feature-grid') ? [...element.parentElement.children].indexOf(element) % 3 * 75 : 0}ms`);
      observer.observe(element);
    });
    function reset() {
      cancelAnimationFrame(frame); frame = 0;
      stage.style.setProperty('--tilt-x', '0deg'); stage.style.setProperty('--tilt-y', '0deg');
      stage.style.setProperty('--shine-opacity', '0');
    }
    function move(event) {
      if (motion.matches || !fine.matches || event.pointerType === 'touch') return;
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const rect = stage.getBoundingClientRect();
        const x = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
        const y = Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height));
        stage.style.setProperty('--tilt-x', `${(y - .5) * -3}deg`);
        stage.style.setProperty('--tilt-y', `${(x - .5) * 4}deg`);
        stage.style.setProperty('--shine-x', `${x * 100}%`);
        stage.style.setProperty('--shine-y', `${y * 100}%`);
        stage.style.setProperty('--shine-opacity', '1');
      });
    }
    stage.addEventListener('pointermove', move, { passive: true });
    stage.addEventListener('pointerleave', reset);
    motion.addEventListener('change', reset); fine.addEventListener('change', reset);
    return () => {
      observer.disconnect(); reset();
      stage.removeEventListener('pointermove', move); stage.removeEventListener('pointerleave', reset);
      motion.removeEventListener('change', reset); fine.removeEventListener('change', reset);
      revealTargets.forEach(element => element.classList.remove('reveal', 'is-revealed'));
    };
  }, [root]);
}
