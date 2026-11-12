import { useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';

type ApiStatus = 'checking' | 'online' | 'offline';

function App() {
  const [apiStatus, setApiStatus] = useState<ApiStatus>('checking');

  useEffect(() => {
    fetch('/api/health')
      .then((response) => {
        if (!response.ok) {
          throw new Error(`Health check failed with status ${response.status}`);
        }

        return response.json();
      })
      .then(() => setApiStatus('online'))
      .catch(() => setApiStatus('offline'));
  }, []);

  const statusText = {
    checking: 'Checking API...',
    online: 'API is online',
    offline: 'API is unavailable',
  }[apiStatus];

  return (
    <main
      style={{
        alignItems: 'center',
        background: '#f0fdf4',
        color: '#14532d',
        display: 'flex',
        fontFamily: 'system-ui, sans-serif',
        justifyContent: 'center',
        minHeight: '100vh',
        padding: '2rem',
        textAlign: 'center',
      }}
    >
      <section>
        <h1>KrishiSahayak AI</h1>
        <p>Vercel deployment is ready.</p>
        <p role="status">{statusText}</p>
      </section>
    </main>
  );
}

const rootElement = document.getElementById('root');

if (!rootElement) {
  throw new Error('Could not find the application root element.');
}

createRoot(rootElement).render(<App />);
