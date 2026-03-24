import { useState, useEffect } from 'react';
import { ThemeProvider, CssBaseline } from '@mui/material';
import { Box, CircularProgress } from '@mui/material';
import theme from './theme.js';
import { LutronProvider } from './context/LutronContext.js';
import { Dashboard } from './components/Dashboard.js';
import { SetupWizard } from './components/setup/SetupWizard.js';

function App() {
  const [isConfigured, setIsConfigured] = useState<boolean | null>(null);
  const [showSetup, setShowSetup] = useState(false);

  useEffect(() => {
    let attempts = 0;
    const maxRetries = 5;

    function checkStatus() {
      fetch('/api/status')
        .then((res) => res.json())
        .then((data) => {
          setIsConfigured(!!data.processorIp || data.connected || data.deviceCount > 0);
        })
        .catch(() => {
          attempts++;
          if (attempts < maxRetries) {
            // Server might be starting up — retry in 2s
            setTimeout(checkStatus, 2000);
          } else {
            // Server unreachable — show dashboard anyway (connection chip will show status)
            setIsConfigured(true);
          }
        });
    }
    checkStatus();
  }, []);

  if (isConfigured === null) {
    return (
      <ThemeProvider theme={theme}>
        <CssBaseline />
        <Box display="flex" alignItems="center" justifyContent="center" height="100vh">
          <CircularProgress color="primary" />
        </Box>
      </ThemeProvider>
    );
  }

  if (!isConfigured || showSetup) {
    return (
      <ThemeProvider theme={theme}>
        <CssBaseline />
        <SetupWizard
          onComplete={() => {
            setIsConfigured(true);
            setShowSetup(false);
            window.location.reload();
          }}
        />
      </ThemeProvider>
    );
  }

  return (
    <ThemeProvider theme={theme}>
      <CssBaseline />
      <LutronProvider>
        <Dashboard onSetup={() => setShowSetup(true)} />
      </LutronProvider>
    </ThemeProvider>
  );
}

export default App;
