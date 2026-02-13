const express = require('express');
const Docker = require('dockerode');
const net = require('net');

const app = express();
const docker = new Docker({ socketPath: '/var/run/docker.sock' });

const HEALTHCHECK_HOST = process.env.HEALTHCHECK_HOST || 'haproxy-healthchecks';
const HEALTHCHECK_TIMEOUT = parseInt(process.env.HEALTHCHECK_TIMEOUT) || 2000;
const UPDATE_INTERVAL = parseInt(process.env.UPDATE_INTERVAL) || 10000;
const PROJECT_NAME = process.env.PROJECT_NAME || null;

// OpenAPI specification
const openApiSpec = {
  openapi: '3.1.0',
  info: {
    title: 'HAF API Node Status',
    version: '1.0.0',
    description: 'Provides health status for all configured HAF API services'
  },
  servers: [
    {
      url: '/status-api',
      description: 'Status API'
    }
  ],
  paths: {
    '/status': {
      get: {
        summary: 'Get status of all APIs',
        description: 'Returns the health status of all configured HAF API services',
        responses: {
          '200': {
            description: 'Successful response',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    apps: {
                      type: 'array',
                      items: {
                        type: 'object',
                        properties: {
                          name: {
                            type: 'string',
                            description: 'API service name'
                          },
                          url_path: {
                            type: 'string',
                            description: 'URL path for the API'
                          },
                          version: {
                            type: 'string',
                            description: 'Version of the application'
                          },
                          status: {
                            type: 'string',
                            enum: ['healthy', 'unhealthy', 'unknown'],
                            description: 'Health status of the service'
                          }
                        },
                        required: ['name', 'url_path', 'version', 'status']
                      }
                    }
                  }
                }
              }
            }
          },
          '500': {
            description: 'Server error',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    error: {
                      type: 'string'
                    }
                  }
                }
              }
            }
          }
        }
      }
    },
    '/status/{app}': {
      get: {
        summary: 'Get status of specific API',
        description: 'Returns the health status of a specific HAF API service',
        parameters: [
          {
            name: 'app',
            in: 'path',
            required: true,
            description: 'API name (e.g., hivemind, hafah)',
            schema: {
              type: 'string'
            }
          }
        ],
        responses: {
          '200': {
            description: 'Successful response',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    name: {
                      type: 'string',
                      description: 'API service name'
                    },
                    url_path: {
                      type: 'string',
                      description: 'URL path for the API'
                    },
                    version: {
                      type: 'string',
                      description: 'Version of the application'
                    },
                    status: {
                      type: 'string',
                      enum: ['healthy', 'unhealthy', 'unknown'],
                      description: 'Health status of the service'
                    }
                  },
                  required: ['name', 'url_path', 'version', 'status']
                }
              }
            }
          },
          '404': {
            description: 'API not found',
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  properties: {
                    error: {
                      type: 'string'
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
};

// Extract version from container: prefer OCI label, fall back to image tag
function getContainerVersion(container) {
  const ociVersion = container.Labels['org.opencontainers.image.version'];
  if (ociVersion) return ociVersion;

  // Fall back to image tag (everything after the last ':')
  const image = container.Image || '';
  const colonIndex = image.lastIndexOf(':');
  if (colonIndex !== -1) return image.substring(colonIndex + 1);

  return 'unknown';
}

// Health check function that properly reads HAProxy agent check responses
async function checkHealth(port, timeout) {
  const DEBUG = process.env.DEBUG_HEALTH_CHECKS === 'true';

  return new Promise((resolve) => {
    const client = new net.Socket();
    let data = '';
    let connected = false;

    const timeoutHandle = setTimeout(() => {
      client.destroy();
      if (DEBUG) {
        console.log(`Health check port ${port}: timeout after ${timeout}ms`);
      }
      resolve(false);
    }, timeout);

    // Track connection success (mimics HAProxy's HTTP check)
    client.once('connect', () => {
      connected = true;
    });

    client.on('data', (chunk) => {
      data += chunk.toString();
    });

    client.on('end', () => {
      clearTimeout(timeoutHandle);

      if (!connected) {
        // Connection failed (like HTTP check failing)
        if (DEBUG) {
          console.log(`Health check port ${port}: connection failed`);
        }
        resolve(false);
      } else if (data.length === 0) {
        // Connected but no data - treat as unhealthy
        if (DEBUG) {
          console.log(`Health check port ${port}: connected but no data received`);
        }
        resolve(false);
      } else {
        // HAProxy agent checks return "up" or "down #reason"
        const isHealthy = data.trim().startsWith('up');
        if (DEBUG) {
          console.log(`Health check port ${port}: connected=true, data="${data.trim()}", healthy=${isHealthy}`);
        }
        resolve(isHealthy);
      }
    });

    client.on('error', (err) => {
      clearTimeout(timeoutHandle);
      if (DEBUG) {
        console.log(`Health check port ${port} error:`, err.message);
      }
      // Connection error - service is down
      resolve(false);
    });

    client.connect(port, HEALTHCHECK_HOST);
  });
}

// Status monitor class for background monitoring
class StatusMonitor {
  constructor() {
    this.status = { apps: [] };
    this.updateInterval = UPDATE_INTERVAL;
  }

  async start() {
    // Initial update
    await this.updateStatus();

    // Schedule continuous updates
    setInterval(() => {
      this.updateStatus().catch(error => {
        console.error('Error updating status:', error);
      });
    }, this.updateInterval);
  }

  async updateStatus() {
    try {
      // Get all containers (we'll filter by project if needed)
      const filterOptions = {};
      if (PROJECT_NAME) {
        filterOptions.label = [`com.docker.compose.project=${PROJECT_NAME}`];
      }

      const containers = await docker.listContainers({
        filters: filterOptions
      });

      // Extract app info and check health in parallel
      const appPromises = [];

      for (const container of containers) {
        const labels = container.Labels;

        // Check if container has swagger labels
        const swaggerUrl = labels['io.hive.swagger.url'];
        if (!swaggerUrl) continue;

        // Check if labels contain comma-separated values (multiple specs)
        if (swaggerUrl.includes(',')) {
          // Split all comma-separated values
          const urls = swaggerUrl.split(',').map(s => s.trim());
          const names = (labels['io.hive.swagger.name'] || '').split(',').map(s => s.trim());
          const orders = (labels['io.hive.swagger.order'] || '').split(',').map(s => s.trim());
          const healthPorts = (labels['io.hive.healthcheck.port'] || '').split(',').map(s => s.trim());
          const healthTimeouts = (labels['io.hive.healthcheck.timeout'] || '').split(',').map(s => s.trim());
          const version = getContainerVersion(container);

          // Create an app entry for each spec
          urls.forEach((url, i) => {
            const order = parseInt(orders[i]) || 999;
            const healthPort = healthPorts[i] || healthPorts[0]; // Fall back to first port if not enough ports
            const healthTimeout = parseInt(healthTimeouts[i] || healthTimeouts[0]) || HEALTHCHECK_TIMEOUT;

            appPromises.push((async () => {
              let status = 'unknown';
              if (healthPort) {
                const isHealthy = await checkHealth(parseInt(healthPort), healthTimeout);
                status = isHealthy ? 'healthy' : 'unhealthy';
              }

              return {
                name: names[i] || 'Unknown',
                url_path: url,
                version,
                status,
                order
              };
            })());
          });
        } else {
          // Single spec (backward compatibility)
          const order = parseInt(labels['io.hive.swagger.order']) || 999;
          const healthPort = labels['io.hive.healthcheck.port'];
          const healthTimeout = parseInt(labels['io.hive.healthcheck.timeout']) || HEALTHCHECK_TIMEOUT;
          const version = getContainerVersion(container);

          appPromises.push((async () => {
            let status = 'unknown';
            if (healthPort) {
              const isHealthy = await checkHealth(parseInt(healthPort), healthTimeout);
              status = isHealthy ? 'healthy' : 'unhealthy';
            }

            return {
              name: labels['io.hive.swagger.name'] || 'Unknown',
              url_path: swaggerUrl,
              version,
              status,
              order
            };
          })());
        }
      }

      const apps = await Promise.all(appPromises);

      // Sort by order label
      apps.sort((a, b) => a.order - b.order);

      // Remove order field from final output
      const cleanedApps = apps.map(({ order, ...app }) => app);

      this.status = { apps: cleanedApps };
      const projectFilter = PROJECT_NAME ? ` (filtered by project: ${PROJECT_NAME})` : ' (all projects)';
      console.log(`Status updated: ${apps.length} apps monitored${projectFilter}`);
    } catch (error) {
      console.error('Error updating status:', error);
      // Keep last known status on error
    }
  }

  getStatus() {
    return this.status;  // Always returns immediately
  }

  getAppStatus(appName) {
    const app = this.status.apps.find(a =>
      a.name.toLowerCase().includes(appName.toLowerCase()) ||
      a.url_path.toLowerCase().includes(appName.toLowerCase())
    );
    return app || null;
  }
}

// Initialize monitor
const monitor = new StatusMonitor();

// Routes
app.get('/', (req, res) => {
  res.json(openApiSpec);
});

app.get('/status', (req, res) => {
  res.json(monitor.getStatus());
});

app.get('/status/:app', (req, res) => {
  const app = monitor.getAppStatus(req.params.app);

  if (app) {
    res.json(app);
  } else {
    res.status(404).json({ error: `API '${req.params.app}' not found` });
  }
});

app.get('/health', (req, res) => {
  res.status(200).send('OK');
});

// Start the server
const PORT = process.env.PORT || 3000;

async function startServer() {
  try {
    // Start background monitoring
    await monitor.start();

    // Start Express server
    app.listen(PORT, () => {
      console.log(`Status API listening on port ${PORT}`);
      console.log(`Background monitoring running every ${UPDATE_INTERVAL}ms`);
    });
  } catch (error) {
    console.error('Failed to start server:', error);
    process.exit(1);
  }
}

startServer();