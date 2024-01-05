import http from "node:http"
import fs from "node:fs"
import {Docker} from "node-docker-api";

const port = process.env.PORT || 80;
const project = process.env.PROJECT;

const server = http.createServer(async (req, res) => {
  if (req.url == '/index.htm' || req.url == '/index.html' || req.url == '/') {
    fs.readFile('./index.js', function(err, data) {
      res.end(data);
    });
  } else if (req.url == '/api/containers') {
    const docker = new Docker({ socketPath: '/var/run/docker.sock' });
    const rawResult = await docker.container.list();
    const extractRequiredInfo = (container) => {
      return {
        labels: container.data.Labels,
        image: container.data.Image,
        imageId: container.data.ImageID,
        id: container.data.Id,
        created: new Date(container.data.Created * 1000),
        status: container.data.Status
      };
    };
    const cookedResult = rawResult.map(extractRequiredInfo).filter(container => container.labels['com.docker.compose.project'] == project);
    //res.statusCode = 200
    res.setHeader('Content-Type', 'application/json; charset=utf-8')
    res.end(JSON.stringify(cookedResult));
  }
})

server.listen(port, () => console.log(`Server running at http://localhost:${port}/`))
