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
-- drop users and logins if they exist and then create new ones
-- ========================
IF EXISTS (SELECT * FROM sys.database_principals WHERE name = 'clientUser')
    DROP USER clientUser;
IF EXISTS (SELECT * FROM sys.server_principals WHERE name = 'clientUser')
    DROP LOGIN clientUser;
GO

CREATE LOGIN clientUser WITH PASSWORD = 'wsOIe6K9*uJ3';
CREATE USER clientUser FOR LOGIN clientUser;

IF EXISTS (SELECT * FROM sys.database_principals WHERE name = 'serverUser')
    DROP USER serverUser;
IF EXISTS (SELECT * FROM sys.server_principals WHERE name = 'serverUser')
    DROP LOGIN serverUser;
GO

CREATE LOGIN serverUser WITH PASSWORD = 'rYTI]{T2768£';
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
            THROW 50001, 'Invalid  CPU Value: must be inbetween of  0 and 100.', 1;

        -- insert measurement
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

-- generate warnings (used by triggers)
CREATE PROCEDURE InsertWarningWithCategory
    @measurementId INT,
    @type VARCHAR(50),
    @description TEXT,
    @severityLevel VARCHAR(20)
AS
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Insert into Warning table
        INSERT INTO Warning (measurementId, type, description, severityLevel)
        VALUES (@measurementId, @type, @description, @severityLevel);

        -- Link to category
        INSERT INTO MeasurementCategory (measurementId, categoryId)
        SELECT @measurementId, categoryId
        FROM Category
        WHERE name = @type;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;

        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
        THROW 70001, @Err, 1;
    END CATCH
END;
GO

-- insert a new computer or update last contact if it already exists
CREATE PROCEDURE InsertComputer
    @hostname VARCHAR(255),
    @ipAddress VARCHAR(50),
    @operatingSystem VARCHAR(100)
AS
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;

        IF EXISTS (SELECT 1 FROM Computer WHERE hostname = @hostname)
        BEGIN
            -- Update lastContact if the computer already exists
            UPDATE Computer
            SET lastContact = GETDATE()
            WHERE hostname = @hostname;
        END
        ELSE
        BEGIN
            -- Insert new computer
            INSERT INTO Computer (hostname, ipAddress, operatingSystem, lastContact)
            VALUES (@hostname, @ipAddress, @operatingSystem, GETDATE());
        END

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK;

        DECLARE @Err NVARCHAR(4000) = ERROR_MESSAGE();
        THROW 60001, @Err, 1;
    END CATCH
END;
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
    DECLARE @measurementId INT;

    SELECT @measurementId = i.measurementId
    FROM inserted i
    WHERE i.cpuUsagePercent > 80;

    IF @measurementId IS NOT NULL
    BEGIN
        EXEC InsertWarningWithCategory
            @measurementId = @measurementId,
            @type = 'HighCPU',
            @description = 'CPU usage > 80%',
            @severityLevel = 'High';
    END
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
    DECLARE @measurementId INT;

    SELECT @measurementId = i.measurementId
    FROM inserted i
    WHERE (i.ramUsedMB * 100.0 / NULLIF(i.ramTotalMB, 0)) > 80;

    IF @measurementId IS NOT NULL
    BEGIN
        EXEC InsertWarningWithCategory
            @measurementId = @measurementId,
            @type = 'HighRAM',
            @description = 'RAM usage > 80%',
            @severityLevel = 'High';
    END
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
    DECLARE @measurementId INT;

    SELECT @measurementId = i.measurementId
    FROM inserted i
    WHERE (i.diskUsedGB * 100.0 / NULLIF(i.diskTotalGB, 0)) > 90;

    IF @measurementId IS NOT NULL
    BEGIN
        EXEC InsertWarningWithCategory
            @measurementId = @measurementId,
            @type = 'LowDisk',
            @description = 'Disk usage > 90%',
            @severityLevel = 'High';
    END
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
-- cerate views
-- ========================

DROP VIEW IF EXISTS vw_DashboardSummary;
GO

-- get summary for dashboard
CREATE VIEW vw_DashboardSummary AS
SELECT
    -- Total registered computers
    (SELECT COUNT(*) FROM Computer) AS computerCount,

    -- Average CPU usage today
    (SELECT ROUND(ISNULL(AVG(cpuUsagePercent), 0), 0)
     FROM Measurement
     WHERE CAST(timestamp AS DATE) = CAST(GETDATE() AS DATE)
    ) AS avgCpuToday,

    -- Average RAM usage (%) today
    (SELECT ROUND(ISNULL(AVG(CAST(ramUsedMB AS FLOAT) * 100.0 / NULLIF(ramTotalMB, 0)), 0), 0)
     FROM Measurement
     WHERE CAST(timestamp AS DATE) = CAST(GETDATE() AS DATE)
    ) AS avgRamUsageToday,

    -- Number of warnings today
    (SELECT COUNT(*)
     FROM Warning w
     JOIN Measurement m ON m.measurementId = w.measurementId
     WHERE CAST(m.timestamp AS DATE) = CAST(GETDATE() AS DATE)
    ) AS warningsToday,

    -- Average number of warnings per day over the last 7 days, excluding today
    (SELECT ROUND(ISNULL(AVG(warningCount), 0), 1)
        FROM (
            SELECT CAST(m.timestamp AS DATE) AS [day], COUNT(*) AS warningCount
            FROM Warning w
            JOIN Measurement m ON m.measurementId = w.measurementId
            WHERE m.timestamp >= CAST(DATEADD(DAY, -7, GETDATE()) AS DATE)
            AND m.timestamp < CAST(GETDATE() AS DATE)
            GROUP BY CAST(m.timestamp AS DATE)
        ) AS dailyWarnings
    ) AS avgWarningsLast7Days;
GO

-- get latest warnings
DROP VIEW IF EXISTS vw_LatestWarnings;
GO

CREATE VIEW vw_LatestWarnings AS
SELECT TOP 10
    w.warningId,
    w.measurementId,
    w.type,
    w.description,
    w.severityLevel,
    m.timestamp,
    c.hostname
FROM Warning w
JOIN Measurement m ON m.measurementId = w.measurementId
JOIN Computer c ON c.computerId = m.computerId
ORDER BY m.timestamp DESC;
GO

-- get latest 10 measurements
DROP VIEW IF EXISTS vw_Latest10Measurements;
GO

CREATE VIEW vw_Latest10Measurements AS
SELECT TOP 10
    c.hostname,
    m.cpuUsagePercent,
    CAST(m.ramUsedMB * 100.0 / NULLIF(m.ramTotalMB, 0) AS INT) AS ramUsagePercent,
    CAST(m.diskUsedGB * 100.0 / NULLIF(m.diskTotalGB, 0) AS INT) AS diskUsagePercent,
    m.uptimeMinutes,
    m.timestamp
FROM Measurement m
JOIN Computer c ON c.computerId = m.computerId
ORDER BY m.timestamp DESC;
GO

-- average cpu usage last 7 days
DROP VIEW IF EXISTS vw_AvgCpuUsageLast7Days;
GO

CREATE VIEW vw_AvgCpuUsageLast7Days AS
SELECT 
    CAST(m.timestamp AS DATE) AS [day],
    ROUND(AVG(m.cpuUsagePercent), 2) AS avgCpuUsage
FROM Measurement m
WHERE m.timestamp >= DATEADD(DAY, -7, CAST(GETDATE() AS DATE))
GROUP BY CAST(m.timestamp AS DATE);
GO

-- average ram usage last 7 days
DROP VIEW IF EXISTS vw_AvgRamUsageLast7Days;
GO

CREATE VIEW vw_AvgRamUsageLast7Days AS
SELECT 
    CAST(m.timestamp AS DATE) AS [day],
    ROUND(AVG(CAST(m.ramUsedMB AS FLOAT) * 100.0 / NULLIF(m.ramTotalMB, 0)), 2) AS avgRamUsagePercent
FROM Measurement m
WHERE m.timestamp >= DATEADD(DAY, -7, CAST(GETDATE() AS DATE))
GROUP BY CAST(m.timestamp AS DATE);
GO

-- warnings by type last 7 days
DROP VIEW IF EXISTS vw_WarningTypeStatsLast7Days;
GO

CREATE VIEW vw_WarningTypeStatsLast7Days AS
WITH AllMeasurements AS (
    SELECT m.measurementId
    FROM Measurement m
    WHERE m.timestamp >= DATEADD(DAY, -7, CAST(GETDATE() AS DATE))
),
WarningCounts AS (
    SELECT
        w.type AS warningType,
        COUNT(*) AS count
    FROM Warning w
    JOIN Measurement m ON m.measurementId = w.measurementId
    WHERE m.timestamp >= DATEADD(DAY, -7, CAST(GETDATE() AS DATE))
    GROUP BY w.type
),
HealthyCount AS (
    SELECT COUNT(*) AS count
    FROM AllMeasurements m
    WHERE NOT EXISTS (
        SELECT 1 FROM Warning w WHERE w.measurementId = m.measurementId
    )
),
Unioned AS (
    SELECT warningType, count FROM WarningCounts
    UNION ALL
    SELECT 'Healthy', count FROM HealthyCount
    WHERE count > 0 -- only include if healthy measurements exist
),
Total AS (
    SELECT SUM(count) AS total FROM Unioned
)
SELECT
    u.warningType,
    u.count,
    ROUND(CAST(u.count AS FLOAT) * 100.0 / NULLIF(t.total, 0), 2) AS percentage
FROM Unioned u
CROSS JOIN Total t;
GO

-- get operating system stats
DROP VIEW IF EXISTS vw_OperatingSystemStats;
GO

CREATE VIEW vw_OperatingSystemStats AS
WITH TotalComputers AS (
    SELECT COUNT(*) AS total FROM Computer
)
SELECT 
    c.operatingSystem,
    COUNT(*) AS count,
    ROUND(CAST(COUNT(*) AS FLOAT) * 100.0 / NULLIF(t.total, 0), 2) AS percentage
FROM Computer c
CROSS JOIN TotalComputers t
GROUP BY c.operatingSystem, t.total;
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
GRANT SELECT ON Computer TO clientUser;
GRANT SELECT ON Category TO clientUser;
GRANT EXECUTE ON InsertMeasurement TO clientUser;
GRANT EXECUTE ON InsertComputer TO clientUser;
GO

-- server user
GRANT SELECT, INSERT, DELETE ON Measurement TO serverUser;
GRANT SELECT, INSERT ON Warning TO serverUser;
GRANT SELECT, INSERT ON MeasurementCategory TO serverUser;
GRANT SELECT ON Computer TO serverUser;
GRANT SELECT ON Category TO serverUser;
GRANT EXECUTE ON InsertComputer TO serverUser;
GRANT SELECT ON vw_DashboardSummary TO serverUser;
GRANT SELECT ON vw_LatestWarnings TO serverUser;
GRANT SELECT ON vw_Latest10Measurements TO serverUser;
GRANT SELECT ON vw_AvgCpuUsageLast7Days TO serverUser;
GRANT SELECT ON vw_AvgRamUsageLast7Days TO serverUser;
GRANT SELECT ON vw_WarningTypeStatsLast7Days TO serverUser;
GRANT SELECT ON vw_OperatingSystemStats TO serverUser;
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