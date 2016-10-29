SELECT isnt(
  queue__create('test SP queue', 'sp')
  , null
  , 'Creation of SP queue works'
);
SELECT isnt(
  queue__create('test SR queue', 'Serial remover')
  , null
  , 'Creation of SR queue works'
);
