import React, { useState, useEffect } from 'react';
import './App.css';
import axios from 'axios';

function App() {
  const [springBootData, setSpringBootData] = useState(null);
  const [fastApiData, setFastApiData] = useState(null);
  const [loading, setLoading] = useState(true);

  const springBootUrl = process.env.REACT_APP_API_URL || 'http://localhost:18080';
  const fastApiUrl = process.env.REACT_APP_FASTAPI_URL || 'http://localhost:18000';

  useEffect(() => {
    const fetchData = async () => {
      try {
        const [springResponse, fastResponse] = await Promise.all([
          axios.get(`${springBootUrl}/api/hello`).catch(() => ({ data: { error: 'Spring Boot unavailable' } })),
          axios.get(`${fastApiUrl}/api/hello`).catch(() => ({ data: { error: 'FastAPI unavailable' } }))
        ]);

        setSpringBootData(springResponse.data);
        setFastApiData(fastResponse.data);
      } catch (error) {
        console.error('Error fetching data:', error);
      } finally {
        setLoading(false);
      }
    };

    fetchData();
  }, [springBootUrl, fastApiUrl]);

  return (
    <div className="App">
      <header className="App-header">
        <h1>DevOps Pipeline Dashboard</h1>
        <p>React Frontend with Blue-Green Deployment</p>

        <div className="status-container">
          <div className="service-box">
            <h2>Spring Boot API</h2>
            {loading ? (
              <p>Loading...</p>
            ) : (
              <pre>{JSON.stringify(springBootData, null, 2)}</pre>
            )}
          </div>

          <div className="service-box">
            <h2>FastAPI Service</h2>
            {loading ? (
              <p>Loading...</p>
            ) : (
              <pre>{JSON.stringify(fastApiData, null, 2)}</pre>
            )}
          </div>
        </div>

        <div className="info-box">
          <p><strong>Environment:</strong> {process.env.NODE_ENV}</p>
          <p><strong>Build Time:</strong> {new Date().toLocaleString()}</p>
        </div>
      </header>
    </div>
  );
}

export default App;
