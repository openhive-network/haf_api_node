<html>
  <head>
    <title>HAF Admin Pages</title>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/picocss/1.5.11/pico.min.css" integrity="sha512-OQffBFLKzDp5Jn8uswDOWJXFNcq64F0N2/Gqd3AtoJrVkSSMMCsB7K7UWRLFyXxm2tYUrNFTv/AX/nkS9zEfxA==" crossorigin="anonymous" referrerpolicy="no-referrer" />
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" integrity="sha512-DTOQO9RWCH3ppGqcWaEA1BIZOC6xxalwEsw9c2QQeAIftl+Vegovlnee1c9QX4TctnWMn13TZye+giMm8e2LwA==" crossorigin="anonymous" referrerpolicy="no-referrer" />
    <script type="module">
      import { html, render, useEffect, useState } from 'https://cdnjs.cloudflare.com/ajax/libs/htm/3.1.1/preact/standalone.module.min.js';

      function containerGitInfoRow(props) {

        const source = props.data.labels['org.opencontainers.image.source'];
        const revision = props.data.labels['org.opencontainers.image.revision'];
        const branch = props.data.labels['io.hive.image.branch'];
        const logMessage = props.data.labels['io.hive.image.commit.log_message'];
        const author = props.data.labels['io.hive.image.commit.author'];
        const commitDate = props.data.labels['io.hive.image.commit.date'];

        // the git info is all custom properties that some containers won't have by default.  If none of the properties are present,
        // don't render anything.
        if ((!source || !revision) && !branch && !logMessage && !author && !commitDate)
          return undefined;

        return html`<tr>
                      <th><i class="fa-brands fa-git-alt fa-xl"></i></th>
                      <td>
                        <table>
                          ${ source && revision ? html`
                          <tr>
                            <th><i class="fa-solid fa-code-commit"></i></th>
                            <td><a href="${source + '/-/commit/' + revision}">${revision?.substring(0, 8)}</a></td>
                          </tr>` : undefined}
                          ${ branch ? html`
                          <tr>
                            <th><i class="fa-solid fa-code-branch"></i></th>
                            <td>${branch}</td>
                          </tr>` : undefined}
                          ${ author ? html`
                          <tr>
                            <th><i class="fa-solid fa-user"></i></th>
                            <td>${author}</td>
                          </tr>` : undefined}
                          ${ commitDate ? html`
                          <tr>
                            <th><i class="fa-solid fa-calendar-days"></i></th>
                            <td>${new Date(commitDate).toLocaleString()}</td>
                          </tr>` : undefined}
                          ${ logMessage ? html`
                          <tr>
                            <th><i class="fa-solid fa-message"></i></th>
                            <td>${logMessage}</td>
                          </tr>` : undefined}
                        </table>
                      </td>
                    </tr>`;
      }

      function containerCard(props) {
        const serviceName = props.data.labels['com.docker.compose.service'];
        const buildTime = props.data.labels['org.opencontainers.image.created'];

        return html`<article>
                      <header>${serviceName}</header>
                      <body>
                        <table>
                          <${containerGitInfoRow} data=${props.data} />
                          <tr>
                            <th><i class="fa-brands fa-docker fa-xl"></i></th>
                            <td>
                              <table>
                                ${ buildTime ? html`
                                <tr>
                                  <th>image created</th>
                                  <td>${new Date(buildTime).toLocaleString()}</td>
                                </tr>` : undefined}
                                <tr>
                                  <th>image</th>
                                  <td>${props.data.image}</td>
                                </tr>
                                <tr>
                                  <th>image id</th>
                                  <td>${props.data.imageId}</td>
                                </tr>
                                <tr>
                                  <th>container id</th>
                                  <td>${props.data.id}</td>
                                </tr>
                                <tr>
                                  <th>container created</th>
                                  <td>${new Date(props.data.created).toLocaleString()}</td>
                                </tr>
                                <tr>
                                  <th>status</th>
                                  <td>${props.data.status}</td>
                                </tr>
                              </table>
                            </td>
                          </tr>
                        </table>
                      </body>
                    </article>`;
      }

      function containerList() {
        const [containers, setContainers] = useState([]);
        useEffect(() => {
          const fetchContainers = async () => {
            const containersJson = await (await fetch('api/containers')).json();
            setContainers(containersJson.sort((lhs, rhs) => lhs.labels['com.docker.compose.service'].localeCompare(rhs.labels['com.docker.compose.service'])));
          };
          fetchContainers().catch(console.error);
        }, []);

        if (!containers)
          return undefined;

        return containers.map(container => html`<${containerCard} data=${container} />`);
      }

      render(html`<${containerList} />`, document.body);
    </script>
  </head>
  <body>
  </body>
</html>
