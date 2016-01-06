/*
-- pp_ddl.sql
-- 
-- Creates DDL API procs
-- Should be run on local database or on a separate "pp" database
-- 
-- All objects are created within the "pp" schema
*/

-- If there is a deadlock, kill this session (we can always rerun it)
SET DEADLOCK_PRIORITY LOW;
-- Concat NULL should yield NULL, which is ANSI-compliant
-- CONCAT_NULL_YIELDS_NULL OFF will be deprecated in future versions
SET CONCAT_NULL_YIELDS_NULL ON;
-- Use ANSI/ISO rules
-- This turns on the following settings:
--   ANSI_NULLS
--   ANSI_NULL_DFLT_ON
--   ANSI_PADDING
--   ANSI_WARNINGS
--   CURSOR_CLOSE_ON_COMMIT
--   IMPLICIT_TRANSACTIONS
--   QUOTED_IDENTIFIER
SET ANSI_DEFAULTS ON;
-- We do not want IMPLICIT_TRANSACTIONS
SET IMPLICIT_TRANSACTIONS OFF;
-- Reduce verbosity of query output
SET NOCOUNT ON;
GO

-- Create pp schema for all pp-related objects
IF	NOT EXISTS (
		SELECT *
		FROM
			INFORMATION_SCHEMA.SCHEMATA
		WHERE
			SCHEMA_NAME = 'pp'
	)
BEGIN
	EXEC('CREATE SCHEMA pp AUTHORIZATION dbo;');
END;
GO

-- Global logging table
IF	NOT EXISTS (
		SELECT *
		FROM
			INFORMATION_SCHEMA.TABLES
		WHERE
			INFORMATION_SCHEMA.TABLES.TABLE_SCHEMA = 'pp'
		AND	INFORMATION_SCHEMA.TABLES.TABLE_NAME   = 'changelog'
	)
BEGIN
	CREATE TABLE pp.changelog (
		id         INT           NOT NULL IDENTITY(1, 1)
			CONSTRAINT PK_log
				PRIMARY KEY NONCLUSTERED
	,	logtime    DATETIME2     NOT NULL
			CONSTRAINT DF_log_logtime
				DEFAULT (SYSUTCDATETIME())
	,	errflag    BIT           NOT NULL
			CONSTRAINT DF_log_errflag
				DEFAULT (0)
	,	objid      INT           NULL
	,	subobjid   INT           NULL
	,	action     CHAR(10)      NULL -- CREATE, DROP, ADD, ALTER, etc.
	,	objtype    CHAR(10)      NULL -- TABLE, COLUMN, INDEX, etc.
	,	dbname     SYSNAME       NULL
	,	schemaname SYSNAME       NULL
	,	objectname SYSNAME       NULL
	,	tablename  SYSNAME       NULL
	,	columnname SYSNAME       NULL
	,	msg        NVARCHAR(MAX) NULL
	)
	ON 'PRIMARY';
	INSERT INTO pp.changelog (action, objtype, objid, dbname, schemaname, objectname, tablename, msg)
	VALUES ('CREATE', 'TABLE', OBJECT_ID('changelog'), DB_NAME(), 'dbo', 'pp.changelog', 'changelog', 'Created table pp.changelog');
	CREATE UNIQUE CLUSTERED INDEX CUX_log_logtime_id ON pp.changelog (logtime, id);
	INSERT INTO pp.changelog (action, objtype, objid, subobjid, dbname, schemaname, objectname, tablename, msg)
	VALUES (
		'CREATE'
	,	'INDEX'
	,	OBJECT_ID('changelog')
	,	(
			SELECT top 1 index_id
			FROM sys.indexes
			WHERE object_id = OBJECT_ID('pp.changelog')
			AND name = 'CUX_log_logtime_id'
		)
	,	DB_NAME()
	,	'pp'
	,	'pp.changelog.CUX_log_logtime_id'
	,	'changelog'
	,	'Created index CUX_log_logtime_id on pp.changelog'
	);
END;
GO

-- Global settings table
IF	NOT EXISTS (
		SELECT *
		FROM
			INFORMATION_SCHEMA.TABLES
		WHERE
			INFORMATION_SCHEMA.TABLES.TABLE_SCHEMA = 'pp'
		AND	INFORMATION_SCHEMA.TABLES.TABLE_NAME   = 'setting'
	)
BEGIN
	CREATE TABLE pp.setting (
		id         INT NOT NULL IDENTITY(1, 1)
			CONSTRAINT PK_setting
				PRIMARY KEY NONCLUSTERED
	,	name  VARCHAR(30) NOT NULL
	,	value VARCHAR(30) NOT NULL
	)
	ON 'PRIMARY';
	INSERT INTO pp.changelog (action, objtype, objid, dbname, schemaname, objectname, tablename, msg)
	VALUES ('CREATE', 'TABLE', OBJECT_ID('setting'), DB_NAME(), 'dbo', 'pp.setting', 'setting', 'Created table pp.setting');
	CREATE UNIQUE CLUSTERED INDEX CUX_setting_name ON pp.setting (name);
	INSERT INTO pp.changelog (action, objtype, objid, subobjid, dbname, schemaname, objectname, tablename, msg)
	VALUES (
		'CREATE'
	,	'INDEX'
	,	OBJECT_ID('setting')
	,	(
			SELECT top 1 index_id
			FROM sys.indexes
			WHERE object_id = OBJECT_ID('setting')
			AND name = 'CUX_setting_name'
		)
	,	DB_NAME()
	,	'dbo'
	,	'pp.setting.CUX_setting_name'
	,	'setting'
	,	'Created index CUX_setting_name on pp.setting'
	);
END;
GO

-- Default settings
IF	NOT EXISTS (
		SELECT *
		FROM
			pp.setting
		WHERE
			pp.setting.name = 'QUOTENAME_DELIMITER'
	)
BEGIN
	INSERT INTO pp.setting (name, value) VALUES ('QUOTENAME_DELIMITER', '[]');
END;
GO

-- Drop functions if they exist
DECLARE @udfs TABLE (id INT NOT NULL IDENTITY(1, 1), udfname SYSNAME NOT NULL);
DECLARE @id INT, @maxid INT, @udfname SYSNAME, @sql NVARCHAR(MAX);
INSERT INTO @udfs (udfname)
VALUES ('tokenizer'), ('condquote'), ('_findobj'), ('_findcol');
SELECT @id = MIN(id) - 1, @maxid = MAX(id) FROM @udfs;
WHILE (@id < @maxid)
BEGIN
	SET	@id += 1;
	SELECT @udfname = udfname FROM @udfs WHERE id = @id;
	IF	(EXISTS (
			SELECT * FROM INFORMATION_SCHEMA.ROUTINES
			WHERE ROUTINE_NAME = @udfname AND ROUTINE_SCHEMA = 'pp' AND ROUTINE_TYPE = 'FUNCTION'
			)
		)
	BEGIN
		SET	@sql = 'DROP FUNCTION pp.' + QUOTENAME(@udfname) + ';';
		EXEC sp_executesql @sql;
	END;
END;
GO

-- tokenizer (@str) RETURNS TABLE
-- 
-- Utility UDF used to tokenize lists of options
-- Smart handling of parentheses and quotes
-- 
-- Ex:
-- 
-- SELECT * FROM pp.tokenizer('foo [bar] "baz" (glorp)');
-- 
-- token   strpos strlen special
-- ------- ------ ------ -------
-- foo          1      3
-- bar          6      3 []
-- baz         12      3 ""
-- glorp       18      5 ()
-- 
CREATE FUNCTION pp.tokenizer(@str NVARCHAR(MAX))
RETURNS @ret TABLE (
	token   NVARCHAR(MAX) NOT NULL
,	strpos  INT           NOT NULL
,	strlen  INT           NOT NULL
,	special CHAR(2)       NULL
)
WITH SCHEMABINDING
AS
BEGIN
	DECLARE
		@strpos    INT           = 0
	,	@maxstrpos INT           = LEN(@str)
	,	@tokenpos  INT           = 1
	,	@strlen    INT           = 0
	,	@char      NCHAR(1)      = NULL
	,	@token     NVARCHAR(MAX) = ''
	,	@special   VARCHAR(2)    = NULL -- not CHAR, to facilitate concatenation
	-- white-space delimiters
	,	@space     CHAR(1)       = ' '
	,	@tab       CHAR(1)       = '	'
	,	@newline   CHAR(2)       = '
'
	,	@cr        CHAR(1)       = CHAR(13)
	,	@lf        CHAR(1)       = CHAR(10)
	-- debugging
	,	@debugflag BIT           = 0
	;
	WHILE @strpos < @maxstrpos
	BEGIN
		SET	@strpos += 1;
		SET	@char = SUBSTRING(@str, @strpos, 1);
		-- Debug
		IF	(@debugflag = 1)
		BEGIN
			INSERT INTO @ret (token, strpos, strlen, special)
			VALUES ('-- @char = ' + ISNULL('''' + @char + '''', '?'), @strpos, 0, @special);
		END;
		-- Check for special nesting characters
		IF	(
				ISNULL(@special, '') = ''
			)
		AND	@char IN ('(', '[', '{', '"', '''')
		BEGIN
			SET	@special = @char;
			-- Debug
			IF	(@debugflag = 1)
			BEGIN
				INSERT INTO @ret (token, strpos, strlen, special)
				VALUES ('-- Open nesting', @strpos, 0, @special);
			END;
		END;
		-- If we are already nesting, check ending
		-- or if not nesting check delimiter
		-- or if we are at the end of the string
		ELSE IF (
				@special + @char IN ('()', '[]', '{}', '""', '''''')
			OR	(
					@char IN (@space, @tab, @newline, @cr, @lf)
				AND	ISNULL(@special, '') = ''
				AND	@token <> ''
				)
			OR	@strpos = @maxstrpos
			)
		BEGIN
			-- Special handling for special nesting
			-- Flush token and reset variables
			IF	(@special + @char IN ('()', '[]', '{}', '""', ''''''))
			BEGIN
				SET	@special += @char;
				SET	@char = '';
				-- Debug
				IF	(@debugflag = 1)
				BEGIN
					INSERT INTO @ret (token, strpos, strlen, special)
					VALUES ('-- Close nesting', @strpos, 0, @special);
				END;
			END;
			IF	@char <> ''
			BEGIN
				SET	@token += @char;
				-- Debug
				IF	(@debugflag = 1)
				BEGIN
					INSERT INTO @ret (token, strpos, strlen, special)
					VALUES ('-- Close token, @token = ' + ISNULL('''' + REPLACE(@token, '''', '''''') + '''', 'NULL'), @strpos, 0, @special);
				END;
			END;
			-- Debug
			IF	(@debugflag = 1)
			BEGIN
				INSERT INTO @ret (token, strpos, strlen, special)
				VALUES ('-- Flush token, @token = ' + ISNULL('''' + REPLACE(@token, '''', '''''') + '''', 'NULL'), @strpos, 0, @special);
			END;
			INSERT INTO @ret (token, strpos, strlen, special)
			VALUES (@token, @tokenpos, @strpos - @tokenpos, @special);
			SET	@token    = '';
			SET	@tokenpos = @strpos;
			SET	@special  = NULL;
		END;
		-- Otherwise, build up the token
		ELSE IF (
					ISNULL(@special, '') <> ''
				OR	@char NOT IN (@space, @tab, @newline, @cr, @lf)
			)
		BEGIN
			IF	@token = ''
			BEGIN
				SET	@tokenpos = @strpos;
				-- Debug
				IF	(@debugflag = 1)
				BEGIN
					INSERT INTO @ret (token, strpos, strlen, special)
					VALUES ('-- Open new token', @strpos, 0, @special);
				END;
			END;
			SET	@token += @char;
			-- Building token
			IF	(@debugflag = 1)
			BEGIN
				INSERT INTO @ret (token, strpos, strlen, special)
				VALUES ('-- Build token, @token = ' + ISNULL('''' + REPLACE(@token, '''', '''''') + '''', 'NULL'), @strpos, 0, @special);
			END;
		END;
	END;
	RETURN;
END;
GO

-- condquote (@objname) RETURNS TABLE
-- 
-- Utility UDF used to quote an object name, if necessary
-- 
-- Ex:
-- 
-- SELECT pp.condquote('foo object');
-- 
-- [foo object]
-- 
-- Note: Uses QUOTENAME_DELIMITER setting in pp.setting
-- 
CREATE FUNCTION pp.condquote(@objname SYSNAME)
RETURNS SYSNAME
WITH SCHEMABINDING
AS
BEGIN
	DECLARE
		@namedelimiter CHAR(2)
	,	@newname       SYSNAME = @objname
	;
	IF	(@objname LIKE '%[^A-Za-z0-9_]%')
	BEGIN
		SELECT
			@namedelimiter = pp.setting.value
		FROM
			pp.setting
		WHERE
			pp.setting.name = 'QUOTENAME_DELIMITER'
		;
		SET	@newname = QUOTENAME(@objname, @namedelimiter);
	END;
	RETURN @newname;
END;
GO

-- _findobj (@str) RETURNS TABLE
-- 
-- Utility UDF used to identify specified object
-- based on 2- or 3-part notation
-- 
-- Ex:
-- 
-- SELECT * FROM pp._findobj('footab');
-- 
-- Note: Because of dependence on DMVs, we cannot schemabind this UDF
CREATE FUNCTION pp._findobj(@str NVARCHAR(MAX))
RETURNS @ret TABLE (
	"schema_id" INT         NULL
,	schemaname  SYSNAME     NULL
,	"object_id" INT         NULL
,	objectname  SYSNAME NOT NULL
)
AS
BEGIN
	DECLARE
		@schema_id  INT
	,	@schemaname SYSNAME
	,	@object_id  INT
	,	@objectname SYSNAME
	,	@strpos     INT
	-- Decompose schemaname.tablename, if necessary
	SET	@strpos = CHARINDEX('.', @str);
	IF	(@strpos > 0)
	BEGIN
		SET	@schemaname = SUBSTRING(@str, 1, @strpos - 1);
		SET	@objectname = SUBSTRING(@str, @strpos + 1, LEN(@str) - @strpos);
		SET	@schema_id  = SCHEMA_ID(@schemaname);
	END;
	ELSE
	BEGIN
		SET	@objectname = @str;
	END;

	-- Find object ID
	IF	(@schema_id IS NOT NULL)
	BEGIN
		SELECT
			@object_id = sys.objects.object_id
		FROM
			sys.objects
		WHERE
			sys.objects.name      = @objectname
		AND	sys.objects.schema_id = @schema_id
		;
	END;
	ELSE
	BEGIN
		SELECT
			TOP 1
			@object_id  = sys.objects.object_id
		,	@schema_id  = sys.schemas.schema_id
		,	@schemaname = sys.schemas.name
		FROM
			sys.objects
			INNER JOIN sys.schemas
			ON	sys.schemas.schema_id = sys.objects.schema_id
		WHERE
			sys.objects.name          = @objectname
		ORDER BY
			sys.schemas.schema_id
		;
	END;
	
	INSERT INTO @ret ("schema_id", schemaname, "object_id", objectname)
	VALUES (@schema_id, @schemaname, @object_id, @objectname);

	RETURN;

END;
GO

-- _findcol (@tablename, @columnname) RETURNS TABLE
-- 
-- Utility UDF used to identify specified column
-- 
-- Ex:
-- 
-- SELECT * FROM pp._findcol('footab', 'foocol');
-- 
-- Note: Because of dependence on DMVs, we cannot schemabind this UDF
CREATE FUNCTION pp._findcol(@tablename NVARCHAR(MAX), @columnname SYSNAME)
RETURNS @ret TABLE (
	"schema_id" INT         NULL
,	schemaname  SYSNAME     NULL
,	"object_id" INT         NULL
,	objectname  SYSNAME NOT NULL
,	"column_id" INT         NULL
,	columnname  SYSNAME NOT NULL
)
AS
BEGIN
	DECLARE
		@schema_id  INT
	,	@schemaname SYSNAME
	,	@object_id  INT
	,	@objectname SYSNAME
	,	@column_id  INT
	,	@strpos     INT
	SELECT
		@schemaname = findobj.schemaname
	,	@schema_id  = findobj."schema_id"
	,	@objectname = findobj.objectname
	,	@object_id  = findobj."object_id"
	FROM
		pp._findobj(@tablename) AS findobj
	;
	
	IF	@object_id IS NOT NULL
	BEGIN
		SELECT
			@column_id = sys.columns.column_id
		FROM
			sys.columns
		WHERE
			sys.columns."object_id" = @object_id
		AND	sys.columns.name        = @columnname
		;
	END;

	INSERT INTO @ret ("schema_id", schemaname, "object_id", objectname, "column_id", columnname)
	VALUES (@schema_id, @schemaname, @object_id, @objectname, @column_id, @columnname);

	RETURN;

END;
GO

-- Stub procs
DECLARE @procs TABLE (id INT NOT NULL IDENTITY(1, 1), procname SYSNAME NOT NULL);
DECLARE @id INT, @maxid INT, @procname SYSNAME, @sql NVARCHAR(MAX);
INSERT INTO @procs (procname)
VALUES ('_ddlcol'), ('addcol'), ('dropcol'), ('altercol');
SELECT @id = MIN(id) - 1, @maxid = MAX(id) FROM @procs;
WHILE (@id < @maxid)
BEGIN
	SET	@id += 1;
	SELECT @procname = procname FROM @procs WHERE id = @id;
	IF	(NOT EXISTS (
			SELECT * FROM INFORMATION_SCHEMA.ROUTINES
			WHERE ROUTINE_NAME = @procname AND ROUTINE_SCHEMA = 'pp' AND ROUTINE_TYPE = 'PROCEDURE'
			)
		)
	BEGIN
		SET	@sql = 'CREATE PROC pp.' + QUOTENAME(@procname) + ' AS RAISERROR(''Stub proc'', 11, 1);';
		EXEC sp_executesql @sql;
	END;
END;
GO

-- _ddlcol <action>, <tablename>, <columnname> [, <datatype> [, '<options...>']]
-- 
-- Internal proc used by addcol, dropcol, altercol
-- 
-- <options> =
--	['NOT NULL' | 'NULL']
--	'DEFAULT (<value>)'
ALTER PROC pp._ddlcol
	@action     CHAR(5) -- ADD, DROP, ALTER
,	@tablename  SYSNAME
,	@columnname SYSNAME
,	@datatype   SYSNAME       = NULL
,	@options    NVARCHAR(MAX) = NULL
AS
BEGIN
	DECLARE
		@schemaname    SYSNAME
	,	@schema_id     INT
	,	@objid         INT
	,	@colid         INT
	-- String processing of @options
	,	@token         NVARCHAR(MAX)
	,	@token2        NVARCHAR(MAX)
	,	@id            INT
	,	@maxid         INT
	-- Processed option values
	,	@notnullflag   BIT           = 0
	,	@defaultvalue  NVARCHAR(MAX) = NULL
	,	@debugflag     BIT           = 0
	,	@noexecflag    BIT           = 0
	-- Dynamic SQL
	,	@sql           NVARCHAR(MAX)
	,	@msg           NVARCHAR(MAX)
	-- Error handling
	,	@errnum        INT
	,	@errsev        INT
	,	@errstate      INT
	,	@errproc       SYSNAME
	,	@errline       INT
	,	@errmsg        NVARCHAR(MAX)
	,	@errflag       BIT = 0
	;

	SELECT
		@schemaname = findcol.schemaname
	,	@schema_id  = findcol."schema_id"
	,	@tablename  = findcol.objectname
	,	@objid      = findcol."object_id"
	,	@columnname = findcol.columnname
	,	@colid      = findcol."column_id"
	FROM
		pp._findcol(@tablename, @columnname) AS findcol
	;

	-- Process options
	DECLARE @opttab TABLE (
		id      INT           NOT NULL IDENTITY(1, 1) PRIMARY KEY CLUSTERED
	,	token   NVARCHAR(MAX) NOT NULL
	,	special CHAR(2)       NULL
	);
	INSERT INTO @opttab (token, special)
	SELECT
		opts.token
	,	opts.special
	FROM
		pp.tokenizer(@options) AS opts
	;
	SELECT
		@id    = 0
	,	@maxid = MAX(opttab.id)
	FROM
		@opttab AS opttab
	;
	WHILE (@id < @maxid)
	BEGIN
		SET	@id += 1;
		SELECT
			@token  = opttab.token
		,	@token2 = nextopttab.token
		FROM
			@opttab AS opttab
			LEFT OUTER JOIN @opttab AS nextopttab
			ON	nextopttab.id = opttab.id + 1
		WHERE
			opttab.id = @id
		;
		-- Nullability
		IF	(@token = 'NOT' AND @token2 = 'NULL')
		BEGIN
			SET	@notnullflag = 1;
			SET	@id += 1;
		END;
		ELSE IF (@token = 'NULL')
		BEGIN
			SET	@notnullflag = 0;
		END;
		-- Default
		IF	(@token = 'DEFAULT' AND @token2 <> '')
		BEGIN
			SET	@defaultvalue = @token2;
			SET	@id += 1;
		END;
		-- Debug
		IF	(@token = '@@DEBUG')
		BEGIN
			SET	@debugflag = 1;
		END;
	END;

	-- Debug
	IF	@debugflag = 1
	BEGIN
		PRINT '/*
EXEC pp._ddlcol
	@action     = ' + ISNULL('''' + REPLACE(@action,     '''', '''''') + '''', 'NULL') + '
,	@tablename  = ' + ISNULL('''' + REPLACE(@tablename,  '''', '''''') + '''', 'NULL') + '
,	@columnname = ' + ISNULL('''' + REPLACE(@columnname, '''', '''''') + '''', 'NULL') + '
,	@datatype   = ' + ISNULL('''' + REPLACE(@datatype,   '''', '''''') + '''', 'NULL') + '
,	@options    = ' + ISNULL('''' + REPLACE(@options,    '''', '''''') + '''', 'NULL') + '
;
*/
';
		SELECT '@opttab' AS '@opttab', * FROM @opttab;
	END;

	-- Check for existence of column
	IF	(	@objid IS NOT NULL
		AND	(	(@action IN ('ADD')           AND @colid IS NULL)
			OR	(@action IN ('ALTER', 'DROP') AND @colid IS NOT NULL)
			)
		)
	BEGIN
		IF	(@action IN ('ADD'))
		BEGIN
			SET	@sql = N'
ALTER TABLE ' + pp.condquote(@schemaname) + '.' + pp.condquote(@tablename) + '
	ADD ' + pp.condquote(@columnname) + ' ' + @datatype;
		END;
		ELSE IF (@action IN ('ALTER'))
		BEGIN
			SET	@sql = N'
ALTER TABLE ' + pp.condquote(@schemaname) + '.' + pp.condquote(@tablename) + '
	ALTER COLUMN ' + pp.condquote(@columnname) + ' ' + @datatype;
		END;
		ELSE IF (@action IN ('DROP'))
		BEGIN
			SET	@sql = N'
ALTER TABLE ' + pp.condquote(@schemaname) + '.' + pp.condquote(@tablename) + '
	DROP COLUMN ' + pp.condquote(@columnname);
		END;
		IF	(@action IN ('ADD', 'ALTER'))
		BEGIN
			IF	(@notnullflag = 1)
			BEGIN
				SET	@sql += ' NOT NULL'
			END;
			ELSE
			BEGIN
				SET	@sql += ' NULL'
			END;
		END;
		IF	(@action IN ('ADD') AND @defaultvalue IS NOT NULL)
		BEGIN
			SET	@sql += '
	CONSTRAINT ' + pp.condquote('DF_' + @tablename + '_' + @columnname) + '
		DEFAULT (' + @defaultvalue + ')'
		END;
		SET	@sql += '
;';
	END;

	IF	(@sql <> '')
	BEGIN
		-- Debug
		IF	@debugflag = 1
		BEGIN
			PRINT @sql;
		END;
		BEGIN TRY
			EXEC sp_executesql @sql;
		END TRY
		BEGIN CATCH
			SELECT
				@errflag  = 1
			,	@errnum   = ERROR_NUMBER()
			,	@errsev   = ERROR_SEVERITY()
			,	@errstate = ERROR_STATE()
			,	@errproc  = ERROR_PROCEDURE()
			,	@errline  = ERROR_LINE()
			,	@errmsg   = ERROR_MESSAGE()
			;
			BEGIN TRY
				SET	@msg = 'ERROR: _ddlcol: Failed DDL action on column ' + pp.condquote(@columnname) +
					' of table ' + pp.condquote(@schemaname) + '.' + pp.condquote(@tablename);
				INSERT INTO pp.changelog (errflag, action, objtype, objid, subobjid, dbname, schemaname, objectname, tablename, msg)
				VALUES (
					@errflag
				,	@action
				,	'COLUMN'
				,	@objid
				,	@colid
				,	DB_NAME()
				,	@schemaname
				,	pp.condquote(@schemaname) + '.' + pp.condquote(@tablename) + '.' + pp.condquote(@columnname)
				,	@tablename
				,	@msg
				);
			END TRY
			BEGIN CATCH
			END CATCH;
			THROW;
		END CATCH;
		IF	@errflag = 1
		BEGIN
			SET	@msg = 'ERROR: _ddlcol: Failed DDL action on column ' + pp.condquote(@columnname) +
				' of table ' + pp.condquote(@schemaname) + '.' + pp.condquote(@tablename);
		END;
		ELSE
		BEGIN
			SET	@msg = '_ddlcol: Completed DDL action on column ' + pp.condquote(@columnname) +
				' of table ' + pp.condquote(@schemaname) + '.' + pp.condquote(@tablename);
		END;
		IF	(@action = 'ADD')
		BEGIN
			SELECT
				@colid = sys.columns.column_id
			FROM
				sys.columns
			WHERE
				sys.columns.object_id = @objid
			AND	sys.columns.name      = @columnname
			;
		END;
		INSERT INTO pp.changelog (errflag, action, objtype, objid, subobjid, dbname, schemaname, objectname, tablename, msg)
		VALUES (
			@errflag
		,	@action
		,	'COLUMN'
		,	@objid
		,	@colid
		,	DB_NAME()
		,	@schemaname
		,	pp.condquote(@schemaname) + '.' + pp.condquote(@tablename) + '.' + pp.condquote(@columnname)
		,	@tablename
		,	@msg
		);
	END;
	ELSE
	BEGIN
		IF	(@debugflag = 1)
		BEGIN
			PRINT '-- _ddlcol: No action taken';
		END;
	END;
END;
GO

-- addcol <tablename>, <columnname>, <datatype> [, '<options...>']
-- 
-- Add specified column on specified table
-- If column exists, do nothing
-- 
-- <options> =
--	['NOT NULL' | 'NULL']
--	'DEFAULT (<value>)'
ALTER PROC pp.addcol
	@tablename  SYSNAME
,	@columnname SYSNAME
,	@datatype   SYSNAME
,	@options    NVARCHAR(MAX) = NULL
AS
BEGIN
	EXEC pp._ddlcol
		@action     = 'ADD'
	,	@tablename  = @tablename
	,	@columnname = @columnname
	,	@datatype   = @datatype
	,	@options    = @options
	;
END;
GO

-- dropcol <tablename>, <columnname> [, '<options...>']
-- 
-- Drop specified column on specified table
-- If column does not exist, do nothing
-- 
-- <options> ...currently not implemented
ALTER PROC pp.dropcol
	@tablename  SYSNAME
,	@columnname SYSNAME
,	@options    NVARCHAR(MAX) = NULL
AS
BEGIN
	EXEC pp._ddlcol
		@action     = 'DROP'
	,	@tablename  = @tablename
	,	@columnname = @columnname
	,	@options    = @options
	;
END;
GO

-- altercol <tablename>, <columnname>, <datatype> [, '<options...>']
-- 
-- Alter specified column on specified table
-- 
-- <options> =
--	['NOT NULL' | 'NULL']
ALTER PROC pp.altercol
	@tablename  SYSNAME
,	@columnname SYSNAME
,	@datatype   SYSNAME
,	@options    NVARCHAR(MAX) = NULL
AS
BEGIN
	EXEC pp._ddlcol
		@action     = 'ALTER'
	,	@tablename  = @tablename
	,	@columnname = @columnname
	,	@datatype   = @datatype
	,	@options    = @options
	;
END;
GO

/*
-- Rollback
BEGIN TRY EXEC('DROP PROC pp._ddlcol;');       END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP PROC pp.addcol;');        END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP PROC pp.dropcol;');       END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP PROC pp.altercol;');      END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP FUNCTION pp.tokenizer;'); END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP FUNCTION pp.condquote;'); END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP FUNCTION pp._findobj;');  END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP FUNCTION pp._findcol;');  END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP TABLE pp.setting;');      END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP TABLE pp.changelog;');    END TRY BEGIN CATCH END CATCH;
BEGIN TRY EXEC('DROP SCHEMA pp;');             END TRY BEGIN CATCH END CATCH;
*/

/*
-- Testing
SELECT * FROM pp.changelog;
SELECT * FROM pp.setting;
EXEC sp_help changelog;
EXEC sp_help setting;
SELECT * FROM pp.tokenizer('foo [bar] "baz" (glorp)');
SELECT pp.condquote('foo');
SELECT pp.condquote('foo [bar] "baz" (glorp)');
CREATE TABLE pp.test (
	id INT NOT NULL IDENTITY(1, 1) PRIMARY KEY
);
EXEC pp.addcol 'test', 'foo', 'varchar(255)', 'NOT NULL DEFAULT (''FOO'') @@DEBUG';
EXEC pp.altercol 'test', 'foo', 'nvarchar(255)', 'NULL @@DEBUG';
EXEC pp.dropcol 'test', 'foo', '@@DEBUG';
DROP TABLE pp.test;
*/
