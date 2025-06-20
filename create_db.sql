-- ========================
-- create database if it does not exists
-- ========================
IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = 'MonitoringDB')
BEGIN
    CREATE DATABASE MonitoringDB;
END
GO

USE MonitoringDB;
GO

-- ========================
-- drop users and logins if they exist  and then create new ones
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

CREATE LOGIN clientUser WITH PASSWORD = 'Client123!';
CREATE USER clientUser FOR LOGIN clientUser;

CREATE LOGIN serverUser WITH PASSWORD = 'Server123!';
CREATE USER serverUser FOR LOGIN serverUser;
GO

-- ========================
-- create tables
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
-- create triggers
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

    -- Link category t owarning
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

    -- Link category to warning
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
    -- insert warning
    INSERT INTO Warning (measurementId, type, description, severityLevel)
    SELECT i.measurementId, 'LowDisk', 'Disk usage > 90%', 'High'
    FROM inserted i
    WHERE (i.diskUsedGB * 100.0 / NULLIF(i.diskTotalGB, 0)) > 90;

    -- link category to warning
    INSERT INTO MeasurementCategory (measurementId, categoryId)
    SELECT i.measurementId, c.categoryId
    FROM inserted i
    JOIN Category c ON c.name = 'LowDisk'
    WHERE (i.diskUsedGB * 100.0 / NULLIF(i.diskTotalGB, 0)) > 90;
END;
GO

--- needs to stay at end, healthy tag (if no other tag isset)
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
-- stored procedures
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
        BEGIN TRANSACTION;

        -- Validierung
        IF @cpuUsage < 0 OR @cpuUsage > 100
            THROW 50001, 'Ungültiger CPU-Wert: muss zwischen 0 und 100 liegen.', 1;

        -- Messung einfügen
        INSERT INTO Measurement (
            computerId,
            cpuUsagePercent,
            ramUsedMB,
            ramTotalMB,
            diskUsedGB,
            diskTotalGB,
            uptimeMinutes
        )
        VALUES (
            @computerId,
            @cpuUsage,
            @ramUsed,
            @ramTotal,
            @diskUsed,
            @diskTotal,
            @uptime
        );

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        THROW 50002, @ErrorMessage, 1;
    END CATCH
END;
GO

-- generate warnings (if you want to create a manual one)
CREATE PROCEDURE InsertWarnings
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

-- system stats
CREATE PROCEDURE GetSystemStats
AS
BEGIN
    BEGIN TRY
        -- last 24h
        SELECT 
            c.hostname,
            COUNT(*) AS totalMeasurements,
            AVG(m.cpuUsagePercent) AS avgCpu,
            MAX(m.cpuUsagePercent) AS maxCpu,
            MIN(m.cpuUsagePercent) AS minCpu
        FROM Measurement m
        JOIN Computer c ON c.computerId = m.computerId
        WHERE m.timestamp > DATEADD(HOUR, -24, GETDATE())
        GROUP BY c.hostname;
    END TRY
    BEGIN CATCH
        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
        THROW 50012, @Err, 1;
    END CATCH
END;
GO

-- get all warnings for a computer
CREATE PROCEDURE GetActiveWarningsForComputer
    @hostname VARCHAR(255)
AS
BEGIN
    BEGIN TRY
        -- check if the host exist
        IF NOT EXISTS (SELECT 1 FROM Computer WHERE hostname = @hostname)
            THROW 50020, 'Computername nicht gefunden.', 1;

        -- get the current warning
        DECLARE @measurementId INT;

        SELECT TOP 1 @measurementId = m.measurementId
        FROM Measurement m
        JOIN Computer c ON c.computerId = m.computerId
        WHERE c.hostname = @hostname
        ORDER BY m.timestamp DESC;

        -- get last warning
        SELECT 
            w.type,
            w.description,
            w.severityLevel,
            m.timestamp
        FROM Warning w
        JOIN Measurement m ON m.measurementId = w.measurementId
        WHERE w.measurementId = @measurementId;
    END TRY
    BEGIN CATCH
        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
        THROW 50021, @Err, 1;
    END CATCH
END;
GO

-- ========================
-- cerate views
-- ========================

-- average CPU usage per computer
CREATE VIEW vw_AvgCpuPerComputer AS
SELECT c.hostname, AVG(m.cpuUsagePercent) AS avgCpu
FROM Measurement m
JOIN Computer c ON c.computerId = m.computerId
GROUP BY c.hostname;
GO

-- latest measurements per computer
CREATE VIEW vw_LatestMeasurements AS
SELECT *
FROM Measurement m
WHERE timestamp = (
    SELECT MAX(m2.timestamp)
    FROM Measurement m2
    WHERE m2.computerId = m.computerId
);
GO

-- warning statistics
CREATE VIEW vw_WarningStats AS
SELECT severityLevel, COUNT(*) AS totalWarnings
FROM Warning
GROUP BY severityLevel;
GO

-- ========================
-- Indexes
-- ========================

CREATE INDEX IX_Measurement_Timestamp ON Measurement (timestamp);
CREATE INDEX IX_Measurement_ComputerId ON Measurement (computerId);
CREATE INDEX IX_Warning_MeasurementId ON Warning (measurementId);
CREATE INDEX IX_Computer_Hostname ON Computer (hostname);
CREATE INDEX IX_MeasurementCategory_CategoryId ON MeasurementCategory (categoryId);

-- ========================
-- permissions
-- ========================

-- client user
GRANT SELECT,  INSERT, UPDATE ON Computer TO clientUser;
GRANT INSERT ON Measurement TO clientUser;
GRANT SELECT ON Category TO clientUser;
GRANT INSERT ON MeasurementCategory TO clientUser;
GRANT EXECUTE ON InsertMeasurement TO clientUser;
GO

-- server user
GRANT SELECT, INSERT, DELETE ON Measurement TO serverUser;
GRANT SELECT, INSERT ON Warning TO serverUser;
GRANT SELECT, INSERT ON MeasurementCategory TO serverUser;
GRANT SELECT ON Computer TO serverUser;
GRANT SELECT ON Category TO serverUser;
GO

-- ========================
-- Fill db with data
-- ========================

-- Categories
INSERT INTO Category (name) VALUES
('HighCPU'),
('LowRAM'),
('LowDisk'),
('Healthy')