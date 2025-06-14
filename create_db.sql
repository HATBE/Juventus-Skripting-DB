-- ========================
-- 1. Create Database if Not Exists
-- ========================
IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = 'MonitoringDB')
BEGIN
    CREATE DATABASE MonitoringDB;
END
GO

USE MonitoringDB;
GO

-- ========================
-- 2. Drop Users and Logins if They Exist (for clean re-run)
-- ========================
IF EXISTS (SELECT * FROM sys.database_principals WHERE name = 'clientUser')
    DROP USER clientUser;
IF EXISTS (SELECT * FROM sys.server_principals WHERE name = 'clientUser')
    DROP LOGIN clientUser;
GO

IF EXISTS (SELECT * FROM sys.database_principals WHERE name = 'serverUser')
    DROP USER serverUser;
IF EXISTS (SELECT * FROM sys.server_principals WHERE name = 'serverUser')
    DROP LOGIN serverUser;
GO

-- ========================
-- 3. Create Users and Logins
-- ========================
CREATE LOGIN clientUser WITH PASSWORD = 'Client123!';
CREATE USER clientUser FOR LOGIN clientUser;

CREATE LOGIN serverUser WITH PASSWORD = 'Server123!';
CREATE USER serverUser FOR LOGIN serverUser;
GO

-- ========================
-- 4. Create Tables
-- ========================
CREATE TABLE Computer (
    computerId INT PRIMARY KEY IDENTITY(1,1),
    hostname VARCHAR(255) NOT NULL,
    ipAddress VARCHAR(50),
    operatingSystem VARCHAR(100),
    lastContact DATETIME
);

CREATE TABLE Measurement (
    measurementId INT PRIMARY KEY IDENTITY(1,1),
    computerId INT NOT NULL,
    timestamp DATETIME NOT NULL DEFAULT GETDATE(),
    cpuUsagePercent FLOAT CHECK (cpuUsagePercent BETWEEN 0 AND 100),
    ramUsedMB INT CHECK (ramUsedMB >= 0),
    ramTotalMB INT CHECK (ramTotalMB >= 0),
    diskUsedGB FLOAT,
    diskTotalGB FLOAT,
    networkReceivedMB FLOAT,
    networkSentMB FLOAT,
    uptimeMinutes INT CHECK (uptimeMinutes >= 0),

    FOREIGN KEY (computerId) REFERENCES Computer(computerId)
        ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE Warning (
    warningId INT PRIMARY KEY IDENTITY(1,1),
    measurementId INT NOT NULL,
    type VARCHAR(50),
    description TEXT,
    severityLevel VARCHAR(20),
    
    FOREIGN KEY (measurementId) REFERENCES Measurement(measurementId)
        ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE Category (
    categoryId INT PRIMARY KEY IDENTITY(1,1),
    name VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE MeasurementCategory (
    measurementId INT NOT NULL,
    categoryId INT NOT NULL,
    PRIMARY KEY (measurementId, categoryId),
    
    FOREIGN KEY (measurementId) REFERENCES Measurement(measurementId)
        ON DELETE CASCADE ON UPDATE CASCADE,
    FOREIGN KEY (categoryId) REFERENCES Category(categoryId)
        ON DELETE CASCADE ON UPDATE CASCADE
);
GO

-- ========================
-- 5. Permissions: clientUser
-- ========================
GRANT SELECT ON Computer TO clientUser;
GRANT INSERT ON Measurement TO clientUser;
GRANT SELECT ON Category TO clientUser;
GRANT INSERT ON MeasurementCategory TO clientUser;
-- No DELETE or UPDATE
GO

-- ========================
-- 6. Permissions: serverUser
-- ========================
GRANT SELECT, INSERT, DELETE ON Measurement TO serverUser;
GRANT SELECT, INSERT ON Warning TO serverUser;
GRANT SELECT, INSERT ON MeasurementCategory TO serverUser;
GRANT SELECT ON Computer, Category TO serverUser;
GRANT SELECT ON Category TO serverUser;
GO

-- ========================
-- 7. Triggers 
-- ========================
CREATE TRIGGER trg_AutoWarningHighCPU
ON Measurement
AFTER INSERT
AS
BEGIN
    INSERT INTO Warning (measurementId, type, description, severityLevel)
    SELECT i.measurementId, 'HighCPU', 'CPU usage > 90%', 'High'
    FROM inserted i
    WHERE i.cpuUsagePercent > 90;
END
GO

-- ========================
-- 8. Stored Procedures
-- ========================

-- Insert new measurement with validation
CREATE PROCEDURE InsertMeasurement
    @computerId INT,
    @cpuUsage FLOAT,
    @ramUsed INT,
    @ramTotal INT,
    @diskUsed FLOAT,
    @diskTotal FLOAT,
    @netRx FLOAT,
    @netTx FLOAT,
    @uptime INT
AS
BEGIN
    BEGIN TRY
        IF @cpuUsage > 100 OR @cpuUsage < 0
            THROW 50001, 'Invalid CPU value', 1;

        INSERT INTO Measurement (computerId, cpuUsagePercent, ramUsedMB, ramTotalMB, diskUsedGB, diskTotalGB, networkReceivedMB, networkSentMB, uptimeMinutes)
        VALUES (@computerId, @cpuUsage, @ramUsed, @ramTotal, @diskUsed, @diskTotal, @netRx, @netTx, @uptime);
    END TRY
    BEGIN CATCH
        PRINT ERROR_MESSAGE();
    END CATCH
END;
GO

-- Archive old measurements
/*CREATE PROCEDURE ArchiveOldMeasurements
    @daysOld INT
AS
BEGIN
    DELETE FROM Measurement
    WHERE timestamp < DATEADD(DAY, -@daysOld, GETDATE());
END;
GO*/

-- Generate warnings (manual batch)
CREATE PROCEDURE GenerateWarnings
AS
BEGIN
    INSERT INTO Warning (measurementId, type, description, severityLevel)
    SELECT m.measurementId, 'High CPU', 'CPU usage > 90%', 'High'
    FROM Measurement m
    WHERE m.cpuUsagePercent > 90
      AND NOT EXISTS (
          SELECT 1 FROM Warning w WHERE w.measurementId = m.measurementId AND w.type = 'High CPU'
      );
END;
GO

-- ========================
-- 9. Views
-- ========================

-- Average CPU usage per computer
CREATE VIEW vw_AvgCpuPerComputer AS
SELECT c.hostname, AVG(m.cpuUsagePercent) AS avgCpu
FROM Measurement m
JOIN Computer c ON c.computerId = m.computerId
GROUP BY c.hostname;
GO

-- Latest measurements per computer
CREATE VIEW vw_LatestMeasurements AS
SELECT *
FROM Measurement m
WHERE timestamp = (
    SELECT MAX(m2.timestamp)
    FROM Measurement m2
    WHERE m2.computerId = m.computerId
);
GO

-- Warning statistics
CREATE VIEW vw_WarningStats AS
SELECT severityLevel, COUNT(*) AS totalWarnings
FROM Warning
GROUP BY severityLevel;
GO
