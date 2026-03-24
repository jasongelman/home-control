import { createTheme } from '@mui/material/styles';

const theme = createTheme({
  palette: {
    mode: 'dark',
    primary: {
      main: '#f5a623',
      light: '#ffbf4a',
      dark: '#c17b00',
    },
    secondary: {
      main: '#4a9eda',
      light: '#7dcfff',
      dark: '#006fa8',
    },
    background: {
      default: '#121212',
      paper: '#1e1e1e',
    },
    success: {
      main: '#4caf50',
    },
    warning: {
      main: '#ff9800',
    },
    error: {
      main: '#f44336',
    },
    text: {
      primary: '#e0e0e0',
      secondary: '#888888',
    },
  },
  typography: {
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
    h5: {
      fontWeight: 700,
    },
    h6: {
      fontWeight: 700,
    },
    subtitle2: {
      fontWeight: 600,
      textTransform: 'uppercase' as const,
      letterSpacing: '0.06em',
      fontSize: '0.75rem',
    },
  },
  shape: {
    borderRadius: 12,
  },
  components: {
    MuiCard: {
      styleOverrides: {
        root: {
          backgroundImage: 'none',
          border: '1px solid rgba(255,255,255,0.08)',
          transition: 'all 0.25s cubic-bezier(0.4,0,0.2,1)',
        },
      },
    },
    MuiButton: {
      styleOverrides: {
        root: {
          textTransform: 'none' as const,
          fontWeight: 600,
          borderRadius: 8,
        },
      },
    },
    MuiChip: {
      styleOverrides: {
        root: {
          fontWeight: 500,
        },
      },
    },
    MuiSlider: {
      styleOverrides: {
        root: {
          height: 6,
        },
        thumb: {
          width: 20,
          height: 20,
          '&:hover, &.Mui-focusVisible': {
            boxShadow: '0 0 12px rgba(245,166,35,0.4)',
          },
        },
      },
    },
    MuiDialog: {
      styleOverrides: {
        paper: {
          backgroundImage: 'none',
          border: '1px solid rgba(255,255,255,0.08)',
        },
      },
    },
    MuiAppBar: {
      styleOverrides: {
        root: {
          backgroundImage: 'none',
        },
      },
    },
  },
});

export default theme;
