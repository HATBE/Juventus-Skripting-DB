-- ========================
-- Create Database if Not Exists
-- ========================
IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = 'MonitoringDB')
BEGIN
    CREATE DATABASE MonitoringDB;
END
GO

USE MonitoringDB;
GO

-- ========================
-- Drop Users and Logins if They Exist (for clean re-run)
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
-- Create Users and Logins
-- ========================
CREATE LOGIN clientUser WITH PASSWORD = 'Client123!';
CREATE USER clientUser FOR LOGIN clientUser;

CREATE LOGIN serverUser WITH PASSWORD = 'Server123!';
CREATE USER serverUser FOR LOGIN serverUser;
GO

-- ========================
-- Create Tables
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
-- Triggers 
-- ========================

-- to high cpu usage
DROP TRIGGER IF EXISTS trg_AutoWarningHighCPU;
GO

CREATE TRIGGER trg_AutoWarningHighCPU
ON Measurement
AFTER INSERT
AS
BEGIN
    -- Insert warning
    INSERT INTO Warning (measurementId, type, description, severityLevel)
    SELECT i.measurementId, 'HighCPU', 'CPU usage > 80%', 'High'
    FROM inserted i
    WHERE i.cpuUsagePercent > 80;

    -- Link category
    INSERT INTO MeasurementCategory (measurementId, categoryId)
    SELECT i.measurementId, c.categoryId
    FROM inserted i
    JOIN Category c ON c.name = 'HighCPU'
    WHERE i.cpuUsagePercent > 80;
END;
GO

-- to high ram usage
DROP TRIGGER IF EXISTS trg_AutoWarningHighRAM;
GO

CREATE TRIGGER trg_AutoWarningHighRAM
ON Measurement
AFTER INSERT
AS
BEGIN
    -- Insert warning
    INSERT INTO Warning (measurementId, type, description, severityLevel)
    SELECT i.measurementId, 'HighRAM', 'RAM usage > 80%', 'High'
    FROM inserted i
    WHERE (i.ramUsedMB * 100.0 / NULLIF(i.ramTotalMB, 0)) > 80;

    -- Link category
    INSERT INTO MeasurementCategory (measurementId, categoryId)
    SELECT i.measurementId, c.categoryId
    FROM inserted i
    JOIN Category c ON c.name = 'HighRAM'
    WHERE (i.ramUsedMB * 100.0 / NULLIF(i.ramTotalMB, 0)) > 80;
END;
GO


-- to high disk usage
DROP TRIGGER IF EXISTS trg_AutoWarningLowDisk;
GO

CREATE TRIGGER trg_AutoWarningLowDisk
ON Measurement
AFTER INSERT
AS
BEGIN
    -- Warning
    INSERT INTO Warning (measurementId, type, description, severityLevel)
    SELECT i.measurementId, 'LowDisk', 'Disk usage > 90%', 'High'
    FROM inserted i
    WHERE (i.diskUsedGB * 100.0 / NULLIF(i.diskTotalGB, 0)) > 90;

    -- Category
    INSERT INTO MeasurementCategory (measurementId, categoryId)
    SELECT i.measurementId, c.categoryId
    FROM inserted i
    JOIN Category c ON c.name = 'LowDisk'
    WHERE (i.diskUsedGB * 100.0 / NULLIF(i.diskTotalGB, 0)) > 90;
END;
GO

--- needs to stay at end, healthy tag
DROP TRIGGER IF EXISTS trg_AutoHealthyFlag;
GO

CREATE TRIGGER trg_AutoHealthyFlag
ON Measurement
AFTER INSERT
AS
BEGIN
    -- Assign "Healthy" tag if no warning for this measurement
    INSERT INTO MeasurementCategory (measurementId, categoryId)
    SELECT i.measurementId, c.categoryId
    FROM inserted i
    CROSS JOIN Category c
    WHERE c.name = 'Healthy'
      AND NOT EXISTS (
          SELECT 1 FROM Warning w WHERE w.measurementId = i.measurementId
      );
END;
GO


-- ========================
-- Stored Procedures
-- ========================

-- Insert new measurement with validation
CREATE PROCEDURE InsertMeasurement
    @computerId INT,
    @cpuUsage FLOAT,
    @ramUsed INT,
    @ramTotal INT,
    @diskUsed FLOAT,
    @diskTotal FLOAT,
    @uptime INT
AS
BEGIN
    BEGIN TRY
        IF @cpuUsage > 100 OR @cpuUsage < 0
            THROW 50001, 'Invalid CPU value', 1;

        INSERT INTO Measurement (computerId, cpuUsagePercent, ramUsedMB, ramTotalMB, diskUsedGB, diskTotalGB, uptimeMinutes)
        VALUES (@computerId, @cpuUsage, @ramUsed, @ramTotal, @diskUsed, @diskTotal, @uptime);
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
-- Views
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

-- ========================
-- Permissions: clientUser
-- ========================
GRANT SELECT,  INSERT, UPDATE ON Computer TO clientUser;
GRANT INSERT ON Measurement TO clientUser;
GRANT SELECT ON Category TO clientUser;
GRANT INSERT ON MeasurementCategory TO clientUser;
GRANT EXECUTE ON InsertMeasurement TO clientUser;
GO

-- ========================
--  Permissions: serverUser
-- ========================
GRANT SELECT, INSERT, DELETE ON Measurement TO serverUser;
GRANT SELECT, INSERT ON Warning TO serverUser;
GRANT SELECT, INSERT ON MeasurementCategory TO serverUser;
GRANT SELECT ON Computer TO serverUser;
GRANT SELECT ON Category TO serverUser;
GO


-- ========================
-- Inserts
-- ========================

-- Categories

INSERT INTO Category (name) VALUES
('HighCPU'),
('LowRAM'),
('LowDisk'),
('Healthy')