const express = require('express');
const fs = require('fs/promises');
const fsSync = require('fs');
const path = require('path');
const compression = require('compression');

const app = express();
const port = 9000;
const repoRoot = path.join(__dirname, 'repo');

// Enable compression
app.use(compression());

// Normalize URL paths
app.use((req, res, next) => {
  req.url = req.url.replace(/\/+/g, '/');
  next();
});

// Set up content types
const setContentType = (type) => (req, res, next) => {
  res.setHeader('Content-Type', type);
  next();
};

// Set cache control for static assets
const setCacheControl = (maxAge) => (req, res, next) => {
  res.setHeader('Cache-Control', `public, max-age=${maxAge}`);
  next();
};

// Parse OPM file content
const parseOpmFile = async (filePath) => {
  try {
    const content = await fs.readFile(filePath, 'utf8');
    const lines = content.split('\n');
    const packageInfo = {};
    
    for (const line of lines) {
      if (line.startsWith('# :opm packagename:')) {
        packageInfo.name = line.split(':').slice(2).join(':').trim();
      } else if (line.startsWith('# :opm packagever:')) {
        packageInfo.version = line.split(':').slice(2).join(':').trim();
      } else if (line.startsWith('# :opm packagedisplay:')) {
        packageInfo.displayname = line.split(':').slice(2).join(':').trim();
      } else if (line.startsWith('# :opm packagedesc:')) {
        packageInfo.description = line.split(':').slice(2).join(':').trim();
      }
    }
    
    return packageInfo.name && packageInfo.version ? packageInfo : null;
  } catch (err) {
    return null;
  }
};

// Get all packages
const getAllPackages = async () => {
  try {
    const packagesDir = path.join(repoRoot, 'packages');
    const files = await fs.readdir(packagesDir);
    const packages = [];
    
    for (const file of files) {
      if (file.endsWith('.opm')) {
        const opmFilePath = path.join(packagesDir, file);
        const packageInfo = await parseOpmFile(opmFilePath);
        if (packageInfo) {
          packages.push(packageInfo);
        }
      }
    }
    
    return packages;
  } catch (err) {
    return [];
  }
};

// Improved home page
app.get('/', async (req, res) => {
  try {
    const packages = await getAllPackages();
    
    const html = `
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>OPM Repository</title>
      <script src="https://cdn.tailwindcss.com"></script>
    </head>
    <body class="bg-gray-100">
      <div class="container mx-auto px-4 py-8">
        <header class="mb-8 text-center">
          <h1 class="text-3xl font-bold text-gray-800 mb-2">Odd Package Manager Repository</h1>
          <p class="text-gray-600">A lightweight package manager for odd systems</p>
          <p class="text-gray-600 text-sm">This package manager is completely rootless</p>
        </header>
        
        <div class="mb-8 bg-white rounded-lg shadow p-6">
          <h2 class="text-xl font-semibold mb-4 text-gray-800">Repository Information</h2>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <p class="mb-2"><span class="font-medium">Total Packages:</span> ${packages.length}</p>
              <p class="mb-2"><span class="font-medium">Repository API:</span> <a href="/packages.json" class="text-blue-600 hover:underline">packages.json</a></p>
            </div>
            <div>
              <p class="mb-2"><span class="font-medium">Install OPM:</span> <code class="bg-gray-100 px-2 py-1 rounded">curl -sSL opm.oddbyte.dev/opminstall.sh > opminstall.sh && sh opminstall.sh</code></p>
            </div>
          </div>
        </div>
        
        <div class="bg-white rounded-lg shadow">
          <div class="px-6 py-4 border-b border-gray-200">
            <h2 class="text-xl font-semibold text-gray-800">Available Packages</h2>
          </div>
          <div class="overflow-x-auto">
            <table class="min-w-full divide-y divide-gray-200">
              <thead class="bg-gray-50">
                <tr>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Name</th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Version</th>
                  <th class="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">Description</th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-gray-200">
                ${packages.map(pkg => `
                  <tr>
                    <td class="px-6 py-4 whitespace-nowrap font-medium text-gray-900">${pkg.name}</td>
                    <td class="px-6 py-4 whitespace-nowrap text-gray-500">${pkg.version}</td>
                    <td class="px-6 py-4 text-gray-500">${pkg.description || 'No description available'}</td>
                  </tr>
                `).join('')}
                ${packages.length === 0 ? '<tr><td colspan="3" class="px-6 py-4 text-center text-gray-500">No packages available</td></tr>' : ''}
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </body>
    </html>
    `;
    
    res.setHeader('Content-Type', 'text/html');
    res.send(html);
  } catch (error) {
    res.status(500).send('Internal Server Error');
  }
});

// Generate packages.json
app.get('/packages.json', setContentType('application/json'), async (req, res) => {
  try {
    const packages = await getAllPackages();
    const packageList = packages
      .map(pkg => `${pkg.name}|${pkg.version}|${pkg.displayname || pkg.name}`)
      .join('\n');
    
    res.send(packageList || '');
  } catch (error) {
    res.status(500).send('Error generating packages list');
  }
});

// Handle dynamic OPM file serving
app.get('/packages/:filename.opm', setContentType('text/plain'), async (req, res) => {
  try {
    const baseFileName = req.params.filename;
    const validExtensions = ['tar', 'zip', 'tar.gz', 'gz', 'xz'];
    const opmFilePath = path.join(repoRoot, 'packages', `${baseFileName}.opm`);
    
    // Check if the .opm file exists
    try {
      await fs.access(opmFilePath);
    } catch (err) {
      return res.status(404).send('Package metadata not found');
    }
    
    // Find corresponding package data file
    let foundFile = null;
    for (const ext of validExtensions) {
      const filePath = path.join(repoRoot, 'packagedata', `${baseFileName}.${ext}`);
      
      try {
        const stats = await fs.stat(filePath);
        foundFile = { path: filePath, ext, size: stats.size };
        break;
      } catch (err) {
        // File doesn't exist with this extension, continue checking
      }
    }
    
    if (!foundFile) {
      return res.status(404).send('Package data not found');
    }
    
    // Read and modify the .opm file
    const data = await fs.readFile(opmFilePath, 'utf8');
    const dynamicContent = `# :opm ext: ${foundFile.ext}\n# :opm filesize: ${foundFile.size}\n# :opm-end:`;
    const modifiedData = data.replace('# :opm-dynamic:', dynamicContent);
    
    res.send(modifiedData);
  } catch (error) {
    res.status(500).send('Error processing package metadata');
  }
});

// Serve package data files with caching
app.use('/packagedata', 
  setContentType('application/octet-stream'),
  setCacheControl(86400), // 1 day cache
  express.static(path.join(repoRoot, 'packagedata'))
);

// Serve installer scripts
const serveScript = (scriptName) => async (req, res) => {
  try {
    const scriptPath = path.join(repoRoot, scriptName);
    const data = await fs.readFile(scriptPath, 'utf8');
    res.setHeader('Content-Type', 'text/plain');
    res.send(data);
  } catch (error) {
    res.status(404).send('Script not found');
  }
};

app.get('/opminstall.sh', serveScript('opminstall.sh'));
app.get('/opm.sh', serveScript('opm.sh'));

// Error handler
app.use((err, req, res, next) => {
  res.status(500).send('Internal Server Error');
});

app.listen(port);
