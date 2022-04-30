pragma solidity ^0.5.0;

contract FisherYatesShuffle {
   
   // the array that gets shuffled
   uint[] public arr;
   
   uint public arraySize;

   // dummy for what VRF would fill in
   uint public randomNumber = 997654321;

   constructor(uint _arraySize) public{
     arraySize = _arraySize;
     arr = new uint[](arraySize);
   }

  // run this first, or include in constructor
  function initArray() public returns( uint ){
      arr = new uint[](arraySize);
      uint i = 0;

      while (i < arraySize ) {
        arr[i] = i + 1;
        i++;
      }
      
   }

   // Active ingredient
   function shuffleArray() public returns( uint ){
      uint i = arr.length;
      uint temp;
      uint r;

      while (i > 1 ) {
        i--;
        temp = arr[i];
        r = randomNumber % i;
        arr[i] = arr[r];
        arr[r] = temp;

      }
   }

}
